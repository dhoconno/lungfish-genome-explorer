import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class LocalWorkflowExecutionServiceTests: XCTestCase {
    func testPrepareOnlyCreatesRunBundleProvenanceAndOperationLogMetadata() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-workflow-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let workflowURL = temp.appendingPathComponent("main.nf")
        try "nextflow.enable.dsl=2\nworkflow { }\n".write(to: workflowURL, atomically: true, encoding: .utf8)
        let readsURL = temp.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: readsURL, atomically: true, encoding: .utf8)
        let outputURL = temp.appendingPathComponent("results", isDirectory: true)
        let request = LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            inputURLs: [readsURL],
            outputDirectory: outputURL,
            params: ["sample": "S1"]
        )
        let operationCenter = OperationCenter()
        let service = LocalWorkflowExecutionService(operationCenter: operationCenter)

        let result = try await service.prepare(request, bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true))

        XCTAssertEqual(result.bundleURL.pathExtension, "lungfishrun")
        let manifest = try LocalWorkflowRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.workflowName, "main")
        XCTAssertEqual(manifest.engine, .nextflow)
        XCTAssertEqual(manifest.executionStatus, .prepared)
        XCTAssertEqual(manifest.statusHistory.map(\.status), [.prepared])
        XCTAssertEqual(manifest.params["sample"], "S1")
        XCTAssertEqual(manifest.params["input"], readsURL.standardizedFileURL.path)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(
            WorkflowRun.self,
            from: Data(contentsOf: result.bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.steps.first?.toolName, "lungfish-cli workflow run")
        XCTAssertEqual(provenance.steps.first?.exitCode, 0)
        XCTAssertTrue(provenance.steps.first?.command.contains("--prepare-only") == true)
        XCTAssertTrue(provenance.steps.first?.outputs.contains { $0.path == result.bundleURL.path } == true)

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.title, "Local Workflow")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.detail.contains(result.bundleURL.path))
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli workflow run") == true)
        XCTAssertTrue(item.cliCommand?.contains("--prepare-only") == true)
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains(result.bundleURL.path) })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("nextflow run") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("prepared") })
        XCTAssertEqual(item.bundleURLs, [result.bundleURL])
    }

    func testRunInvokesCLIWithBundlePathAndRecordsOperationMetadata() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-workflow-run-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let workflowURL = temp.appendingPathComponent("main.nf")
        try "nextflow.enable.dsl=2\nworkflow { }\n".write(to: workflowURL, atomically: true, encoding: .utf8)
        let outputURL = temp.appendingPathComponent("results", isDirectory: true)
        let request = LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            outputDirectory: outputURL,
            params: ["sample": "S1"]
        )
        let operationCenter = OperationCenter()
        let runner = StubLocalWorkflowCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "prepared bundle\nworkflow complete\n",
            standardError: ""
        ))
        let service = LocalWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(request, bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.workingDirectory, result.bundleURL.standardizedFileURL)
        XCTAssertTrue(invocation.arguments.starts(with: ["workflow", "run", workflowURL.standardizedFileURL.path]))
        XCTAssertTrue(invocation.arguments.contains("--bundle-path"))
        XCTAssertTrue(invocation.arguments.contains(result.bundleURL.path))
        XCTAssertTrue(invocation.arguments.contains("--results-dir"))
        XCTAssertTrue(invocation.arguments.contains(outputURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--param"))
        XCTAssertTrue(invocation.arguments.contains("sample=S1"))
        XCTAssertFalse(invocation.arguments.contains("--prepare-only"))

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli workflow run") == true)
        XCTAssertTrue(item.cliCommand?.contains(result.bundleURL.path) == true)
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("Run bundle: \(result.bundleURL.path)") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("nextflow run") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("workflow complete") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("completed") })
        XCTAssertEqual(item.bundleURLs, [result.bundleURL])
    }
}

private final class StubLocalWorkflowCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: LocalWorkflowCLIProcessResult

    init(result: LocalWorkflowCLIProcessResult) {
        self.result = result
    }

    func runLungfishCLI(arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowCLIProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL
        ))
        if result.exitCode == 0 {
            try writeCompletedBundle(arguments: arguments)
        }
        return result
    }

    private func writeCompletedBundle(arguments: [String]) throws {
        let bundleURL = URL(fileURLWithPath: try value(after: "--bundle-path", in: arguments)).standardizedFileURL
        let workflowURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: try value(after: "--results-dir", in: arguments)).standardizedFileURL
        let inputURLs = values(afterEvery: "--input", in: arguments).map { URL(fileURLWithPath: $0).standardizedFileURL }
        let request = LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            inputURLs: inputURLs,
            outputDirectory: outputURL,
            params: params(from: arguments)
        )
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                executionStatus: .completed,
                startedAt: Date(),
                completedAt: Date(),
                exitCode: 0
            ),
            to: bundleURL
        )

        let step = StepExecution(
            toolName: "lungfish-cli workflow run",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish-cli"] + arguments,
            inputs: [ProvenanceRecorder.fileRecord(url: workflowURL, format: .text, role: .input)]
                + inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) },
            outputs: [
                FileRecord(path: bundleURL.path, format: .unknown, role: .output),
                FileRecord(path: outputURL.path, format: .unknown, role: .output),
                ProvenanceRecorder.fileRecord(url: bundleURL.appendingPathComponent("manifest.json"), format: .json, role: .output),
            ],
            exitCode: 0,
            wallTime: 0.01,
            stderr: result.standardError,
            endTime: Date()
        )
        let run = WorkflowRun(
            name: "Run Local Workflow",
            endTime: Date(),
            status: .completed,
            steps: [step],
            parameters: request.effectiveParams.mapValues { .string($0) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(domain: "LocalWorkflowExecutionServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"])
        }
        return arguments[arguments.index(after: index)]
    }

    private func values(afterEvery flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            arguments[index] == flag && arguments.indices.contains(arguments.index(after: index))
                ? arguments[arguments.index(after: index)]
                : nil
        }
    }

    private func params(from arguments: [String]) -> [String: String] {
        values(afterEvery: "--param", in: arguments).reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            result[parts[0]] = parts[1]
        }
    }
}
