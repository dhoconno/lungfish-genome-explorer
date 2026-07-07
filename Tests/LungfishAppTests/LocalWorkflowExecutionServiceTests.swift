import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishKit

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

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result.bundleURL))
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.toolName, "lungfish-cli workflow run")
        XCTAssertTrue(provenance.argv.contains("--prepare-only"))
        XCTAssertTrue(provenance.outputs.contains { $0.path == result.bundleURL.standardizedFileURL.path })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.bundleURL
                    .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                    .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                    .path
            )
        )

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

    func testRunRejectsLegacyOnlyRootWorkflowRunProvenance() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-workflow-run-legacy-provenance-\(UUID().uuidString)", isDirectory: true)
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
        let runner = StubLocalWorkflowCLIProcessRunner(
            result: .init(exitCode: 0, standardOutput: "workflow complete\n", standardError: ""),
            provenanceMode: .legacyWorkflowRun
        )
        let service = LocalWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        do {
            _ = try await service.run(request, bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true))
            XCTFail("Expected legacy-only root WorkflowRun provenance to be rejected.")
        } catch LocalWorkflowExecutionError.invalidProvenance(let path) {
            XCTAssertTrue(path.hasSuffix(ProvenanceRecorder.provenanceFilename))
        }
    }
}

private final class StubLocalWorkflowCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    enum ProvenanceMode {
        case canonicalEnvelope
        case legacyWorkflowRun
    }

    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: LocalWorkflowCLIProcessResult
    let provenanceMode: ProvenanceMode

    init(result: LocalWorkflowCLIProcessResult, provenanceMode: ProvenanceMode = .canonicalEnvelope) {
        self.result = result
        self.provenanceMode = provenanceMode
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
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
        switch provenanceMode {
        case .canonicalEnvelope:
            let stepEnvelope = ProvenanceStep(stepExecution: step)
            let envelope = ProvenanceEnvelope(
                workflowName: run.name,
                workflowVersion: WorkflowRun.currentAppVersion,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                tool: ProvenanceToolIdentity(name: step.toolName, version: step.toolVersion, kind: "cli"),
                argv: step.command,
                options: ProvenanceOptions(explicit: run.parameters),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                files: stepEnvelope.inputs + stepEnvelope.outputs,
                output: stepEnvelope.outputs.first,
                outputs: stepEnvelope.outputs,
                steps: [stepEnvelope],
                wallTimeSeconds: step.wallTime,
                exitStatus: Int(step.exitCode ?? 0),
                stderr: step.stderr
            )
            try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
        case .legacyWorkflowRun:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run).write(
                to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
                options: .atomic
            )
        }
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
