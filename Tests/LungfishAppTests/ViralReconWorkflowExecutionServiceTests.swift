import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class ViralReconWorkflowExecutionServiceTests: XCTestCase {
    func testServiceCreatesRunBundleAndLogsPreparation() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "nextflow progress\ncompleted sample SARS2_A",
            standardError: "nextflow warning"
        ))
        runner.onRun = {
            let item = try XCTUnwrap(operationCenter.items.first)
            XCTAssertTrue(item.detail.contains("illumina"))
            XCTAssertTrue(item.detail.contains("1 sample(s)"))
            XCTAssertTrue(item.detail.contains("MN908947.3"))
        }
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        XCTAssertEqual(result.bundleURL.pathExtension, "lungfishrun")
        let persistedSamplesheet = result.bundleURL.appendingPathComponent("inputs/samplesheet.csv")
        let persistedPrimerBED = result.bundleURL.appendingPathComponent("inputs/primers/primers.bed")
        let persistedPrimerFASTA = result.bundleURL.appendingPathComponent("inputs/primers/primers.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedSamplesheet.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedPrimerBED.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedPrimerFASTA.path))
        XCTAssertEqual(
            try String(contentsOf: persistedSamplesheet, encoding: .utf8),
            try String(contentsOf: request.samplesheetURL, encoding: .utf8)
        )
        XCTAssertEqual(
            try String(contentsOf: persistedPrimerBED, encoding: .utf8),
            try String(contentsOf: request.primer.bedURL, encoding: .utf8)
        )
        XCTAssertEqual(
            try String(contentsOf: persistedPrimerFASTA, encoding: .utf8),
            try String(contentsOf: request.primer.fastaURL, encoding: .utf8)
        )

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains(persistedSamplesheet.path))
        XCTAssertTrue(invocation.arguments.contains("primer_bed=\(persistedPrimerBED.path)"))
        XCTAssertTrue(invocation.arguments.contains("primer_fasta=\(persistedPrimerFASTA.path)"))
        XCTAssertFalse(invocation.arguments.contains(request.samplesheetURL.path))
        XCTAssertEqual(runner.invocations.first?.workingDirectory, result.bundleURL)

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.workflowName, "viralrecon")
        XCTAssertEqual(manifest.version, "3.0.0")
        XCTAssertEqual(manifest.executor, .docker)
        XCTAssertEqual(manifest.params["input"], persistedSamplesheet.path)
        XCTAssertEqual(manifest.params["primer_bed"], persistedPrimerBED.path)
        XCTAssertEqual(manifest.params["primer_fasta"], persistedPrimerFASTA.path)

        XCTAssertEqual(
            try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stdout.log"), encoding: .utf8),
            "nextflow progress\ncompleted sample SARS2_A"
        )
        XCTAssertEqual(
            try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stderr.log"), encoding: .utf8),
            "nextflow warning"
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.operationType, .viralRecon)
        XCTAssertEqual(item.title, "Viral Recon")
        XCTAssertTrue(item.cliCommand?.contains(persistedSamplesheet.path) == true)
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("samplesheet") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("lungfish-cli workflow run nf-core/viralrecon") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("nextflow progress") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("nextflow warning") })
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.detail.contains(request.outputDirectory.path))
        XCTAssertTrue(item.detail.contains(result.bundleURL.path))
        XCTAssertEqual(item.bundleURLs, [result.bundleURL])
    }

    func testServiceFailsWithExitCodeAndStderrTail() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let stderr = (1...45).map { "stderr line \($0)" }.joined(separator: "\n") + "\nbad params"
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 2,
            standardOutput: "",
            standardError: stderr
        ))
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        do {
            _ = try await service.run(
                request,
                bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
            )
            XCTFail("Expected Viral Recon service to throw for a non-zero CLI exit")
        } catch {
            XCTAssertEqual(error as? ViralReconWorkflowExecutionError, .nonZeroExit(2))
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.detail.contains("exit code 2"))
        XCTAssertEqual(item.errorMessage, "Viral Recon failed")
        XCTAssertTrue(item.errorDetail?.contains("exit code 2") == true)
        XCTAssertTrue(item.errorDetail?.contains("bad params") == true)
        XCTAssertFalse(item.errorDetail?.components(separatedBy: .newlines).contains("stderr line 1") == true)
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("bad params") })
    }

    func testServiceAllocatesUniqueBundleNames() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let analyses = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(
            at: analyses.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true),
            withIntermediateDirectories: true
        )
        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "", standardError: ""))
        )

        let result = try await service.run(request, bundleRoot: analyses)

        XCTAssertEqual(result.bundleURL.lastPathComponent, "viralrecon-2.lungfishrun")
    }

    func testServicePersistsNanoporeInputsAndUsesPersistedPaths() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.nanoporeRequest(root: temp)
        let runner = StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "", standardError: ""))
        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let persistedFastqPass = result.bundleURL.appendingPathComponent("inputs/nanopore/fastq_pass", isDirectory: true)
        let persistedSummary = result.bundleURL.appendingPathComponent("inputs/nanopore/sequencing_summary.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedFastqPass.appendingPathComponent("barcode01/reads.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedSummary.path))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains("fastq_dir=\(persistedFastqPass.path)"))
        XCTAssertTrue(invocation.arguments.contains("sequencing_summary=\(persistedSummary.path)"))
        XCTAssertFalse(invocation.arguments.contains("fastq_dir=\(try XCTUnwrap(request.fastqPassDirectoryURL).path)"))

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.params["fastq_dir"], persistedFastqPass.path)
        XCTAssertEqual(manifest.params["sequencing_summary"], persistedSummary.path)
    }

    func testCommandPreviewQuotesShellMetacharactersWithoutWhitespace() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral&recon'\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "", standardError: ""))
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        let command = try XCTUnwrap(item.cliCommand)
        let persistedSamplesheet = result.bundleURL.appendingPathComponent("inputs/samplesheet.csv")
        XCTAssertTrue(command.contains("'\(shellEscapedInner(persistedSamplesheet.path))'"))
        XCTAssertFalse(command.contains(" --input \(persistedSamplesheet.path)"))
    }

    func testCommandPreviewQuotesEmptyArguments() {
        XCTAssertEqual(
            ViralReconWorkflowCommandPreview.build(
                executableName: "lungfish-cli",
                arguments: ["workflow", ""]
            ),
            "lungfish-cli workflow ''"
        )
    }

    func testServiceDoesNotDuplicateProcessLinesWhenRunnerStreamsAndReturnsOutput() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = StreamingStubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "streamed stdout\n",
            standardError: "streamed stderr\n"
        ))
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.logEntries.map(\.message).filter { $0 == "streamed stdout" }.count, 1)
        XCTAssertEqual(item.logEntries.map(\.message).filter { $0 == "streamed stderr" }.count, 1)
    }

    func testServiceDoesNotReplayReturnedOutputWhenResultReportsStreaming() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "queued stdout\n",
            standardError: "queued stderr\n",
            didStreamOutput: true
        ))
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        let messages = item.logEntries.map { $0.message }
        XCTAssertFalse(messages.contains("queued stdout"))
        XCTAssertFalse(messages.contains("queued stderr"))
    }

    func testConcreteRunnerStreamsOutputBeforeProcessReturns() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        var received: [ViralReconWorkflowProcessOutput] = []

        let task = Task {
            try await runner.runLungfishCLI(
                arguments: ["-c", "printf 'stdout-ready\\n'; printf 'stderr-ready\\n' >&2; sleep 1; printf 'stdout-done\\n'"],
                workingDirectory: temp,
                outputHandler: { output in
                    received.append(output)
                }
            )
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(received.contains(.standardOutput("stdout-ready")))
        XCTAssertTrue(received.contains(.standardError("stderr-ready")))
        XCTAssertFalse(received.contains(.standardOutput("stdout-done")))
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("stdout-ready"))
        XCTAssertTrue(result.standardOutput.contains("stdout-done"))
        XCTAssertTrue(result.standardError.contains("stderr-ready"))
        XCTAssertTrue(result.didStreamOutput)
    }
}

@MainActor
private final class StubViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: ViralReconWorkflowProcessResult
    var onRun: (() throws -> Void)?

    init(result: ViralReconWorkflowProcessResult) {
        self.result = result
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        invocations.append(Invocation(arguments: arguments, workingDirectory: workingDirectory))
        try onRun?()
        return result
    }
}

@MainActor
private final class StreamingStubViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    let result: ViralReconWorkflowProcessResult

    init(result: ViralReconWorkflowProcessResult) {
        self.result = result
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        outputHandler?(.standardOutput("streamed stdout"))
        outputHandler?(.standardError("streamed stderr"))
        return ViralReconWorkflowProcessResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            didStreamOutput: outputHandler != nil
        )
    }
}

private func shellEscapedInner(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}
