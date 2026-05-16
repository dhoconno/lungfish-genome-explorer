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
                arguments: ["-c", "printf 'stdout-ready\\n'; printf 'stderr-ready\\n' >&2; sleep 3; printf 'stdout-done\\n'"],
                workingDirectory: temp,
                outputHandler: { output in
                    received.append(output)
                }
            )
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline
            && !(received.contains(.standardOutput("stdout-ready"))
                 && received.contains(.standardError("stderr-ready"))) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
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

    func testConcreteRunnerCancelTerminatesProcessTree() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let fakeCLI = temp.appendingPathComponent("lungfish-cli")
        let readyURL = temp.appendingPathComponent("ready")
        let rootPIDURL = temp.appendingPathComponent("root.pid")
        let childPIDURL = temp.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        echo $$ > '\(rootPIDURL.path)'
        /bin/sh -c 'trap "" TERM HUP; sleep 3 & wait' &
        child=$!
        echo "$child" > '\(childPIDURL.path)'
        touch '\(readyURL.path)'
        wait "$child"
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: fakeCLI)
        let runTask = Task {
            try await runner.runLungfishCLI(
                arguments: [],
                workingDirectory: temp,
                outputHandler: nil
            )
        }

        try await waitForFile(readyURL)
        let rootPID = try readPID(rootPIDURL)
        let childPID = try readPID(childPIDURL)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
        }

        let cancelStart = Date()
        runner.cancel()
        let cancelReturnElapsed = Date().timeIntervalSince(cancelStart)
        XCTAssertLessThan(cancelReturnElapsed, 0.25, "ViralRecon cancel() should only request process-tree termination")
        try await waitForProcessExit(pid: childPID)
        _ = try await runTask.value

        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: rootPID), "ViralRecon root process should exit after cancellation")
    }

    func testOperationCenterCancelCallbackCancelsViralReconRunner() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = CancelRecordingViralReconProcessRunner()
        runner.onRun = {
            guard let operationID = operationCenter.items.first?.id else {
                XCTFail("Expected Viral Recon operation to be registered before process launch")
                return
            }
            operationCenter.cancel(id: operationID)
        }
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        XCTAssertEqual(result.operationItem?.state, .cancelled)
        try await waitUntil(timeout: 2) {
            runner.cancelCallCount == 1
        }
    }

    func testViralReconProcessRunnerCancelTerminatesCurrentProcessTreeSource() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("func cancel()"))
        let processRunnerSource = try XCTUnwrap(
            source.range(of: "ProcessViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning")
        )
        let cancelBody = try functionBody(
            named: "cancel",
            in: String(source[processRunnerSource.lowerBound...])
        )

        XCTAssertTrue(cancelBody.contains("requestProcessTreeTermination()"))
    }
}

final class PipelineCancelCallbackRegressionTests: XCTestCase {
    func testAppDelegateLongRunningPipelineStartSitesInstallCancelCallbacks() throws {
        let source = try appDelegateSource()
        for functionName in [
            "runSequenceAnnotationOperation",
            "runMinimap2Mapping",
            "runManagedMapping",
            "runOrientReads",
        ] {
            let body = try functionBody(named: functionName, in: source)
            XCTAssertTrue(
                body.contains("let task = Task.detached"),
                "\(functionName) should keep the detached task handle for cancellation"
            )
            XCTAssertTrue(
                body.contains("OperationCenter.shared.setCancelCallback(for: opID)"),
                "\(functionName) should wire OperationCenter cancellation"
            )
            XCTAssertTrue(
                body.contains("task.cancel()"),
                "\(functionName) cancel callback should cancel the detached task"
            )
        }

        let sequenceBody = try functionBody(named: "runSequenceAnnotationOperation", in: source)
        XCTAssertTrue(sequenceBody.contains("LungfishCLIRunner.CancellationHandle()"))
        XCTAssertTrue(sequenceBody.contains("cancellation: cliCancellation"))
        XCTAssertTrue(sequenceBody.contains("cliCancellation.cancel()"))
    }

    func testMAFFTStartSiteCancelsDetachedTaskAndRunnerProcess() throws {
        let body = try functionBody(named: "runMAFFTAlignment", in: appDelegateSource())

        XCTAssertTrue(body.contains("let runner = CLIMSAAlignmentRunner()"))
        XCTAssertTrue(body.contains("let task = Task.detached"))
        XCTAssertTrue(body.contains("try await runner.run("))
        XCTAssertTrue(body.contains("OperationCenter.shared.setCancelCallback(for: opID)"))
        XCTAssertTrue(body.contains("task.cancel()"))
        XCTAssertTrue(body.contains("runner.cancel()"))
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

    func cancel() {}
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

    func cancel() {}
}

@MainActor
private final class CancelRecordingViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    private(set) var cancelCallCount = 0
    var onRun: (() -> Void)?

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        onRun?()
        return ViralReconWorkflowProcessResult(
            exitCode: 0,
            standardOutput: "cancelled",
            standardError: "",
            didStreamOutput: false
        )
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private func shellEscapedInner(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func appDelegateSource() throws -> String {
    try String(
        contentsOf: repositoryRoot().appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
        encoding: .utf8
    )
}

private func functionBody(named name: String, in source: String) throws -> String {
    let signature = "func \(name)"
    let signatureRange = try XCTUnwrap(source.range(of: signature), "Missing \(signature)")
    let openBrace = try XCTUnwrap(
        source[signatureRange.lowerBound...].firstIndex(of: "{"),
        "Missing opening brace for \(signature)"
    )
    var depth = 0
    var index = openBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openBrace...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    XCTFail("Missing closing brace for \(signature)")
    return ""
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for \(url.path)")
}

@MainActor
private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for condition")
}

private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !ProcessTreeTerminator.processExists(pid: pid) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Process \(pid) was still running after cancellation")
}

private func readPID(_ url: URL) throws -> Int32 {
    let text = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try XCTUnwrap(Int32(text), "Expected pid in \(url.path)")
}
