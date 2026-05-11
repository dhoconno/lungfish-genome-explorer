import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class WorkflowBuilderRunServiceTests: XCTestCase {
    func testRunCreatesDurableRunRecordProvenanceAndOperationRows() async throws {
        let fixture = try makeFixture()
        var graph = WorkflowGraph(name: "Reads to Trim")
        let sampleInput = graph.addNode(type: .fastqInput, position: .zero, label: "Sample input")
        let trimming = graph.addNode(type: .trimming, position: .zero)
        let projectOutput = graph.addNode(type: .export, position: .zero, label: "Project output")
        _ = try graph.addConnection(
            sourceNodeId: sampleInput.id,
            sourcePortId: "reads",
            targetNodeId: trimming.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimming.id,
            sourcePortId: "trimmed",
            targetNodeId: projectOutput.id,
            targetPortId: "input"
        )
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter) { _, _ in }
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        let result = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)

        XCTAssertEqual(result.runDirectoryURL.lastPathComponent, result.runID.uuidString)
        XCTAssertEqual(result.runDirectoryURL.deletingLastPathComponent().lastPathComponent, "runs")
        let record = try WorkflowBuilderRunStore.readRun(runID: result.runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.workflowName, "Reads to Trim")
        XCTAssertEqual(record.graphID, graph.id)
        XCTAssertFalse(record.graphChecksumSHA256.isEmpty)
        XCTAssertEqual(record.binding.sample.path, fixture.sampleURL.standardizedFileURL.path)
        XCTAssertEqual(record.binding.project.path, fixture.projectURL.standardizedFileURL.path)
        XCTAssertEqual(record.nodeRecords.map(\.status), [.succeeded, .succeeded, .succeeded])
        XCTAssertEqual(record.provenance.toolName, "Lungfish Workflow Builder")
        XCTAssertEqual(record.provenance.exitStatus, 0)
        XCTAssertTrue(record.provenance.argv.contains("run"))
        XCTAssertTrue(record.provenance.inputs.contains { $0.path == fixture.sampleURL.standardizedFileURL.path })
        XCTAssertTrue(record.provenance.outputs.contains { $0.path == result.runDirectoryURL.standardizedFileURL.path })

        let runRows = operationCenter.items.filter { $0.workflowRunID == result.runID }
        XCTAssertEqual(runRows.count, 4)
        XCTAssertTrue(runRows.contains { $0.title == "Workflow Run: Reads to Trim" && $0.state == .completed })
        XCTAssertTrue(runRows.contains { $0.title == "Sample input" && $0.state == .completed })
        XCTAssertTrue(runRows.contains { $0.title == "Trimming" && $0.state == .completed })
        XCTAssertTrue(runRows.contains { $0.title == "Project output" && $0.state == .completed })
    }

    func testFirstFailingNodeMarksRunFailedAndSkipsDownstreamNodes() async throws {
        let fixture = try makeFixture()
        var graph = WorkflowGraph(name: "Failing Workflow")
        let sampleInput = graph.addNode(type: .fastqInput, position: .zero, label: "Sample input")
        let trimming = graph.addNode(type: .trimming, position: .zero)
        let qc = graph.addNode(type: .qualityControl, position: .zero)
        let projectOutput = graph.addNode(type: .export, position: .zero, label: "Project output")
        _ = try graph.addConnection(
            sourceNodeId: sampleInput.id,
            sourcePortId: "reads",
            targetNodeId: trimming.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimming.id,
            sourcePortId: "trimmed",
            targetNodeId: qc.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: qc.id,
            sourcePortId: "report",
            targetNodeId: projectOutput.id,
            targetPortId: "input"
        )
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter) { node, _ in
            if node.id == trimming.id {
                throw WorkflowBuilderRunService.ExecutionError.nodeFailed(nodeID: node.id, message: "fastp exited 2")
            }
        }
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        do {
            _ = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)
            XCTFail("Expected run failure")
        } catch WorkflowBuilderRunService.ExecutionError.nodeFailed(let nodeID, let message) {
            XCTAssertEqual(nodeID, trimming.id)
            XCTAssertEqual(message, "fastp exited 2")
        }

        let runID = try XCTUnwrap(operationCenter.items.first?.workflowRunID)
        let record = try WorkflowBuilderRunStore.readRun(runID: runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, "fastp exited 2")
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == trimming.id }?.status, .failed)
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == qc.id }?.status, .skipped)
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == projectOutput.id }?.status, .skipped)
        XCTAssertTrue(operationCenter.items.contains { $0.workflowRunID == runID && $0.title == "Trimming" && $0.state == .failed })
        XCTAssertFalse(operationCenter.items.contains { $0.workflowRunID == runID && $0.title == "Quality Control" })
    }

    func testDefaultRunnerFailsUnsupportedScientificGraphInsteadOfMarkingNodesSucceeded() async throws {
        let fixture = try makeFixture()
        var graph = WorkflowGraph(name: "Unsupported Reference Export")
        let reference = graph.addNode(type: .fastaInput, position: .zero, label: "Reference input")
        let projectOutput = graph.addNode(type: .export, position: .zero, label: "Project output")
        _ = try graph.addConnection(
            sourceNodeId: reference.id,
            sourcePortId: "sequence",
            targetNodeId: projectOutput.id,
            targetPortId: "input"
        )
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter)
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        do {
            _ = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)
            XCTFail("Expected unsupported production workflow failure")
        } catch WorkflowBuilderRunService.ExecutionError.nodeFailed(let nodeID, let message) {
            XCTAssertEqual(nodeID, reference.id)
            XCTAssertTrue(message.contains("Unsupported Workflow Builder input node"))
            XCTAssertTrue(message.contains("Reference input"))
        }

        let runID = try XCTUnwrap(operationCenter.items.first?.workflowRunID)
        let record = try WorkflowBuilderRunStore.readRun(runID: runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.provenance.exitStatus, 1)
        XCTAssertEqual(record.provenance.stderr, record.errorMessage)
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == reference.id }?.status, .failed)
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == projectOutput.id }?.status, .skipped)
        XCTAssertFalse(record.nodeRecords.allSatisfy { $0.status == .succeeded })
    }

    func testDefaultRunnerDispatchesSupportedFastqGraphThroughLocalWorkflowCLIAndRecordsProvenance() async throws {
        let fixture = try makeFixture()
        var graph = WorkflowGraph(name: "Reads to Trim")
        let sampleInput = graph.addNode(type: .fastqInput, position: .zero, label: "Sample input")
        let trimming = try graph.addStableNode(
            id: UUID(),
            type: .trimming,
            label: nil,
            position: .zero,
            parameters: ["minimum_length": "25", "qualified_quality_phred": "20"]
        )
        let projectOutput = graph.addNode(type: .export, position: .zero, label: "Project output")
        _ = try graph.addConnection(
            sourceNodeId: sampleInput.id,
            sourcePortId: "reads",
            targetNodeId: trimming.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimming.id,
            sourcePortId: "trimmed",
            targetNodeId: projectOutput.id,
            targetPortId: "input"
        )
        let operationCenter = OperationCenter()
        let runner = ProvenanceWritingWorkflowCLIProcessRunner()
        let service = WorkflowBuilderRunService(
            operationCenter: operationCenter,
            localWorkflowProcessRunner: runner
        )
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        let result = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.starts(with: ["workflow", "run"]))
        let exportedWorkflowURL = URL(fileURLWithPath: invocation.arguments[2])
        let exportedScript = try String(contentsOf: exportedWorkflowURL, encoding: .utf8)
        XCTAssertTrue(exportedScript.contains("fastp -i ${reads} -o trimmed.fastq.gz"))
        XCTAssertTrue(exportedScript.contains("--length_required 25"))
        XCTAssertTrue(invocation.arguments.contains("--input"))
        XCTAssertTrue(invocation.arguments.contains(fixture.sampleURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--param"))
        XCTAssertTrue(invocation.arguments.contains("sample_input=\(fixture.sampleURL.standardizedFileURL.path)"))

        let record = try WorkflowBuilderRunStore.readRun(runID: result.runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, WorkflowBuilderRunStatus.succeeded)
        XCTAssertEqual(
            record.nodeRecords.map(\.status),
            [
                WorkflowBuilderNodeRunStatus.succeeded,
                WorkflowBuilderNodeRunStatus.succeeded,
                WorkflowBuilderNodeRunStatus.succeeded,
            ]
        )
        XCTAssertEqual(record.provenance.exitStatus, 0)
        XCTAssertTrue(record.provenance.outputs.contains { $0.path == invocation.bundleURL.standardizedFileURL.path })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let localProvenance = try decoder.decode(
            WorkflowRun.self,
            from: Data(contentsOf: invocation.bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        let step = try XCTUnwrap(localProvenance.steps.first)
        XCTAssertEqual(step.toolName, "lungfish-cli workflow run")
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertTrue(step.command.contains("lungfish-cli"))
        XCTAssertTrue(step.command.contains(exportedWorkflowURL.path))
        XCTAssertTrue(step.inputs.contains { $0.path == fixture.sampleURL.appendingPathComponent("reads.fastq").standardizedFileURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(step.outputs.contains { $0.path == invocation.bundleURL.standardizedFileURL.path })
        XCTAssertTrue(operationCenter.items.contains { $0.title == "Local Workflow" && $0.state == .completed })
    }

    func testDefaultRunnerDispatchesFastqBundleGraphThroughBuilderRunCLIAndRequiresOutputProvenance() async throws {
        let fixture = try makeFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/A.lungfishfastq")
        let operationCenter = OperationCenter()
        let runner = ProvenanceWritingBuilderRunCLIProcessRunner()
        let service = WorkflowBuilderRunService(
            operationCenter: operationCenter,
            localWorkflowProcessRunner: runner
        )
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        let result = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["workflow", "builder-run"])
        XCTAssertTrue(invocation.arguments.contains("--workflow"))
        XCTAssertTrue(invocation.arguments.contains(fixture.workflowBundleURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--project"))
        XCTAssertTrue(invocation.arguments.contains(fixture.projectURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--run-directory"))
        XCTAssertEqual(invocation.workingDirectory.lastPathComponent, result.runID.uuidString)

        let record = try WorkflowBuilderRunStore.readRun(runID: result.runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertTrue(record.provenance.outputs.contains { $0.path == invocation.outputBundleURL.path })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outputProvenance = try decoder.decode(
            WorkflowRun.self,
            from: Data(contentsOf: invocation.outputBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(outputProvenance.status, .completed)
        XCTAssertTrue(outputProvenance.steps.contains { $0.toolName == "lungfish-cli workflow builder-run" })
        XCTAssertTrue(operationCenter.items.contains { $0.title == "Workflow Builder Runner" && $0.state == .completed })
    }

    func testDefaultRunnerRejectsFastqBundleGraphWhenBuilderRunOutputProvenanceIsMissing() async throws {
        let fixture = try makeFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/A.lungfishfastq")
        let operationCenter = OperationCenter()
        let runner = ProvenanceWritingBuilderRunCLIProcessRunner(omitOutputProvenance: true)
        let service = WorkflowBuilderRunService(
            operationCenter: operationCenter,
            localWorkflowProcessRunner: runner
        )
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        do {
            _ = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)
            XCTFail("Expected missing provenance failure")
        } catch WorkflowBuilderRunService.ExecutionError.nodeFailed(let nodeID, let message) {
            XCTAssertEqual(nodeID, graph.allNodes.first { $0.type == .fastqBundleInput }?.id)
            XCTAssertTrue(message.contains("missing .lungfish-provenance.json"))
        }

        let runID = try XCTUnwrap(operationCenter.items.first { $0.title.hasPrefix("Workflow Run:") }?.workflowRunID)
        let record = try WorkflowBuilderRunStore.readRun(runID: runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.provenance.exitStatus, 1)
        XCTAssertTrue(operationCenter.items.contains { $0.title == "Workflow Builder Runner" && $0.state == .failed })
    }

    func testValidationFailureDoesNotCreateRunRows() async throws {
        let fixture = try makeFixture()
        let graph = WorkflowGraph(name: "Empty")
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter)
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        do {
            _ = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)
            XCTFail("Expected validation failure")
        } catch WorkflowBuilderRunService.ExecutionError.validationFailed(let issues) {
            XCTAssertTrue(issues.contains(.emptyWorkflow))
        }

        XCTAssertTrue(operationCenter.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workflowBundleURL.appendingPathComponent("runs").path))
    }

    func testSampleDiscoverySelectsActiveSampleDeterministically() throws {
        let fixture = try makeFixture()
        let second = fixture.projectURL.appendingPathComponent("Imports/B.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let samples = WorkflowBuilderRunSampleDiscovery.discoverSamples(
            in: fixture.projectURL,
            preferredSampleURL: second
        )

        XCTAssertEqual(samples.map(\.url.lastPathComponent), ["B.lungfishfastq", "A.lungfishfastq"])
        XCTAssertEqual(samples.first?.displayName, "B")
    }

    private struct Fixture {
        let root: URL
        let projectURL: URL
        let sampleURL: URL
        let workflowBundleURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-builder-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let sampleURL = projectURL.appendingPathComponent("Imports/A.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: sampleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )
        let workflowBundleURL = projectURL.appendingPathComponent("Workflows/test.lungfishflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workflowBundleURL, withIntermediateDirectories: true)
        return Fixture(root: root, projectURL: projectURL, sampleURL: sampleURL, workflowBundleURL: workflowBundleURL)
    }
}

private final class ProvenanceWritingWorkflowCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
        let bundleURL: URL
    }

    private(set) var invocations: [Invocation] = []

    func runLungfishCLI(arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowCLIProcessResult {
        let bundleURL = URL(fileURLWithPath: try value(after: "--bundle-path", in: arguments)).standardizedFileURL
        let workflowURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: try value(after: "--results-dir", in: arguments)).standardizedFileURL
        let inputURLs = values(afterEvery: "--input", in: arguments).map { URL(fileURLWithPath: $0).standardizedFileURL }
        invocations.append(Invocation(arguments: arguments, workingDirectory: workingDirectory.standardizedFileURL, bundleURL: bundleURL))

        let request = LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            inputURLs: inputURLs,
            outputDirectory: outputURL,
            params: params(from: arguments)
        )
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                executionStatus: .completed,
                statusHistory: [
                    LocalWorkflowRunStatusEvent(status: .prepared),
                    LocalWorkflowRunStatusEvent(status: .running),
                    LocalWorkflowRunStatusEvent(status: .completed),
                ],
                startedAt: Date(),
                completedAt: Date(),
                exitCode: 0
            ),
            to: bundleURL
        )

        let command = ["lungfish-cli"] + arguments
        let outputs = [
            FileRecord(path: bundleURL.path, format: .unknown, role: .output),
            FileRecord(path: outputURL.path, format: .unknown, role: .output),
            ProvenanceRecorder.fileRecord(url: bundleURL.appendingPathComponent("manifest.json"), format: .json, role: .output),
        ]
        let step = StepExecution(
            toolName: "lungfish-cli workflow run",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: [ProvenanceRecorder.fileRecord(url: workflowURL, format: .text, role: .input)]
                + inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) },
            outputs: outputs,
            exitCode: 0,
            wallTime: 0.01,
            stderr: "",
            endTime: Date()
        )
        let run = WorkflowRun(
            name: "Run Local Nextflow workflow",
            endTime: Date(),
            status: .completed,
            steps: [step],
            parameters: request.effectiveParams.mapValues { .string($0) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)

        return LocalWorkflowCLIProcessResult(
            exitCode: 0,
            standardOutput: "workflow complete\n",
            standardError: ""
        )
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(domain: "WorkflowBuilderRunServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"])
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

private final class ProvenanceWritingBuilderRunCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
        let outputBundleURL: URL
    }

    private(set) var invocations: [Invocation] = []
    private let omitOutputProvenance: Bool

    init(omitOutputProvenance: Bool = false) {
        self.omitOutputProvenance = omitOutputProvenance
    }

    func runLungfishCLI(arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowCLIProcessResult {
        let runDirectoryURL = URL(fileURLWithPath: try value(after: "--run-directory", in: arguments)).standardizedFileURL
        let workflowURL = URL(fileURLWithPath: try value(after: "--workflow", in: arguments)).standardizedFileURL
        let outputBundleURL = runDirectoryURL
            .appendingPathComponent("outputs", isDirectory: true)
            .appendingPathComponent("A-VSP2.lungfishfastq", isDirectory: true)
            .standardizedFileURL
        invocations.append(Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL,
            outputBundleURL: outputBundleURL
        ))

        try FileManager.default.createDirectory(at: outputBundleURL, withIntermediateDirectories: true)
        let fastqURL = outputBundleURL.appendingPathComponent("A.fastq")
        try "@processed\nACGT\n+\n!!!!\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        if !omitOutputProvenance {
            try writeProvenance(workflowURL: workflowURL, outputBundleURL: outputBundleURL, fastqURL: fastqURL, arguments: arguments)
        }

        return LocalWorkflowCLIProcessResult(
            exitCode: 0,
            standardOutput: """
            Output bundle: \(outputBundleURL.path)
            Provenance: \(outputBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path)

            """,
            standardError: ""
        )
    }

    private func writeProvenance(
        workflowURL: URL,
        outputBundleURL: URL,
        fastqURL: URL,
        arguments: [String]
    ) throws {
        let step = StepExecution(
            toolName: "lungfish-cli workflow builder-run",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish-cli"] + arguments,
            inputs: [
                ProvenanceRecorder.fileRecord(
                    url: workflowURL.appendingPathComponent("graph.json"),
                    format: .json,
                    role: .input
                ),
            ],
            outputs: [
                ProvenanceRecorder.fileRecord(url: fastqURL, format: .fastq, role: .output),
                FileRecord(path: outputBundleURL.path, format: .unknown, role: .output),
            ],
            exitCode: 0,
            wallTime: 0.01,
            stderr: "",
            endTime: Date()
        )
        let run = WorkflowRun(
            name: "VSP2 FASTQ Workflow",
            endTime: Date(),
            status: .completed,
            steps: [step],
            parameters: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(
            to: outputBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            options: .atomic
        )
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(domain: "WorkflowBuilderRunServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"])
        }
        return arguments[arguments.index(after: index)]
    }
}
