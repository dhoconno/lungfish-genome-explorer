import Foundation
import LungfishWorkflow

public struct WorkflowBuilderRunSample: Sendable, Equatable {
    public let displayName: String
    public let url: URL

    public init(displayName: String, url: URL) {
        self.displayName = displayName
        self.url = url.standardizedFileURL
    }
}

public enum WorkflowBuilderRunSampleDiscovery {
    private static let supportedSampleExtensions: Set<String> = [
        "lungfishfastq",
        "lungfishref",
        "lungfishmsa",
        "lungfishassembly",
    ]

    public static func discoverSamples(in projectURL: URL, preferredSampleURL: URL? = nil) -> [WorkflowBuilderRunSample] {
        let fileManager = FileManager.default
        let preferredPath = preferredSampleURL?.standardizedFileURL.path
        let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var samples: [WorkflowBuilderRunSample] = []
        while let url = enumerator?.nextObject() as? URL {
            guard supportedSampleExtensions.contains(url.pathExtension.lowercased()) else { continue }
            samples.append(WorkflowBuilderRunSample(
                displayName: url.deletingPathExtension().lastPathComponent,
                url: url
            ))
            enumerator?.skipDescendants()
        }

        return samples.sorted { lhs, rhs in
            if lhs.url.path == preferredPath { return true }
            if rhs.url.path == preferredPath { return false }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
    }
}

@MainActor
public final class WorkflowBuilderRunService {
    public struct RunResult: Sendable, Equatable {
        public let runID: UUID
        public let runDirectoryURL: URL
        public let parentOperationID: UUID
    }

    public enum ExecutionError: Error, Equatable {
        case validationFailed([WorkflowValidationIssue])
        case nodeFailed(nodeID: UUID, message: String)
    }

    public typealias NodeExecutor = @MainActor (WorkflowNode, WorkflowBuilderRunBinding) async throws -> Void
    private typealias GraphExecutor = @MainActor (
        WorkflowGraph,
        URL,
        WorkflowBuilderRunBinding,
        UUID,
        URL,
        OperationRouteContext?
    ) async throws -> GraphExecutionResult

    private struct GraphExecutionResult {
        let bundleURL: URL
    }

    private enum ExecutionMode {
        case graph(GraphExecutor)
        case nodes(NodeExecutor)
    }

    private let operationCenter: OperationCenter
    private let executionMode: ExecutionMode

    public init(operationCenter: OperationCenter = .shared) {
        self.operationCenter = operationCenter
        self.executionMode = .graph(Self.makeDefaultGraphExecutor(
            operationCenter: operationCenter,
            processRunner: ProcessLocalWorkflowCLIProcessRunner()
        ))
    }

    public init(operationCenter: OperationCenter = .shared, nodeExecutor: @escaping NodeExecutor) {
        self.operationCenter = operationCenter
        self.executionMode = .nodes(nodeExecutor)
    }

    init(operationCenter: OperationCenter = .shared, localWorkflowProcessRunner: LocalWorkflowCLIProcessRunning) {
        self.operationCenter = operationCenter
        self.executionMode = .graph(Self.makeDefaultGraphExecutor(
            operationCenter: operationCenter,
            processRunner: localWorkflowProcessRunner
        ))
    }

    public func run(
        graph: WorkflowGraph,
        workflowBundleURL: URL,
        binding: WorkflowBuilderRunBinding,
        routeContext: OperationRouteContext? = nil
    ) async throws -> RunResult {
        let issues = graph.validate()
        let blockingIssues = issues.filter { $0.severity == .error }
        guard blockingIssues.isEmpty else {
            throw ExecutionError.validationFailed(blockingIssues)
        }

        let startedAt = Date()
        let runID = UUID()
        let runDirectoryURL = WorkflowBuilderRunStore.runDirectory(runID: runID, in: workflowBundleURL)
        let sortedNodes = try graph.topologicalSort()
        let graphChecksum = try WorkflowBuilderRunStore.graphChecksum(for: graph)
        let argv = [
            "Lungfish",
            "Tools > Workflow Builder",
            "run",
            workflowBundleURL.standardizedFileURL.path,
            "--sample",
            binding.sample.path,
            "--project",
            binding.project.path,
            "--run-id",
            runID.uuidString,
        ]

        let parentOperationID = operationCenter.start(
            title: "Workflow Run: \(graph.name)",
            detail: "Running workflow \(runID.uuidString)",
            operationType: .workflow,
            targetBundleURL: workflowBundleURL,
            cliCommand: argv.map(shellEscapeForWorkflowBuilder).joined(separator: " "),
            workflowRunID: runID,
            routeContext: routeContext
        )
        operationCenter.log(id: parentOperationID, level: .info, message: "Run ID: \(runID.uuidString)")
        operationCenter.log(id: parentOperationID, level: .info, message: "Sample: \(binding.sample.path)")
        operationCenter.log(id: parentOperationID, level: .info, message: "Project: \(binding.project.path)")

        var record = makeInitialRecord(
            runID: runID,
            graph: graph,
            workflowBundleURL: workflowBundleURL,
            graphChecksum: graphChecksum,
            binding: binding,
            nodes: sortedNodes,
            startedAt: startedAt,
            argv: argv,
            runDirectoryURL: runDirectoryURL
        )
        try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)

        var additionalOutputs: [LocalWorkflowInputBinding] = []
        switch executionMode {
        case .graph(let graphExecutor):
            for node in sortedNodes {
                setNodeStatus(node.id, in: &record, status: .running, startedAt: Date())
            }
            try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)

            do {
                let executionResult = try await graphExecutor(graph, workflowBundleURL, binding, runID, runDirectoryURL, routeContext)
                additionalOutputs.append(LocalWorkflowInputBinding(url: executionResult.bundleURL, role: .output))
                for node in sortedNodes {
                    setNodeStatus(node.id, in: &record, status: .succeeded, completedAt: Date())
                }
                operationCenter.update(
                    id: parentOperationID,
                    progress: 1,
                    detail: "Executed workflow through local workflow runner"
                )
                try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)
            } catch {
                let failingNodeID = failingNodeID(from: error) ?? sortedNodes.first?.id
                let message = errorMessage(for: error)
                if let failingNodeID {
                    setNodeStatus(failingNodeID, in: &record, status: .failed, completedAt: Date(), errorMessage: message)
                }
                markUnfinishedNodesSkipped(in: &record, except: failingNodeID)
                record.status = .failed
                record.completedAt = Date()
                record.errorMessage = message
                record.provenance.exitStatus = 1
                record.provenance.wallTimeSeconds = record.completedAt?.timeIntervalSince(startedAt)
                record.provenance.stderr = message
                try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)
                operationCenter.fail(id: parentOperationID, detail: "Workflow failed: \(message)", errorMessage: "Workflow failed", errorDetail: message)
                if let failingNode = sortedNodes.first(where: { $0.id == failingNodeID }) {
                    throw normalizedNodeFailure(error, node: failingNode, message: message)
                }
                throw error
            }

        case .nodes(let nodeExecutor):
            for (index, node) in sortedNodes.enumerated() {
                let nodeOperationID = operationCenter.start(
                    title: node.label,
                    detail: "Running workflow node",
                    operationType: .workflow,
                    targetBundleURL: workflowBundleURL,
                    cliCommand: argv.map(shellEscapeForWorkflowBuilder).joined(separator: " "),
                    workflowRunID: runID,
                    routeContext: routeContext
                )
                setNodeStatus(node.id, in: &record, status: .running, startedAt: Date())
                try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)

                do {
                    try await nodeExecutor(node, binding)
                    setNodeStatus(node.id, in: &record, status: .succeeded, completedAt: Date())
                    operationCenter.complete(id: nodeOperationID, detail: "Completed workflow node")
                    operationCenter.update(id: parentOperationID, progress: Double(index + 1) / Double(sortedNodes.count), detail: "Completed \(node.label)")
                    try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)
                } catch {
                    let message = errorMessage(for: error)
                    setNodeStatus(node.id, in: &record, status: .failed, completedAt: Date(), errorMessage: message)
                    markPendingNodesSkipped(in: &record)
                    record.status = .failed
                    record.completedAt = Date()
                    record.errorMessage = message
                    record.provenance.exitStatus = 1
                    record.provenance.wallTimeSeconds = record.completedAt?.timeIntervalSince(startedAt)
                    record.provenance.stderr = message
                    try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)
                    operationCenter.fail(id: nodeOperationID, detail: message, errorMessage: "Workflow node failed", errorDetail: message)
                    operationCenter.fail(id: parentOperationID, detail: "Workflow failed: \(message)", errorMessage: "Workflow failed", errorDetail: message)
                    throw normalizedNodeFailure(error, node: node, message: message)
                }
            }
        }

        record.status = .succeeded
        record.completedAt = Date()
        if !additionalOutputs.isEmpty {
            record.provenance.outputs.append(contentsOf: additionalOutputs)
        }
        record.provenance.exitStatus = 0
        record.provenance.wallTimeSeconds = record.completedAt?.timeIntervalSince(startedAt)
        try WorkflowBuilderRunStore.write(record, to: workflowBundleURL)
        operationCenter.complete(
            id: parentOperationID,
            detail: "Workflow completed. Run bundle: \(runDirectoryURL.path)",
            outputURLs: [workflowBundleURL]
        )

        return RunResult(runID: runID, runDirectoryURL: runDirectoryURL, parentOperationID: parentOperationID)
    }

    private static func makeDefaultGraphExecutor(
        operationCenter: OperationCenter,
        processRunner: LocalWorkflowCLIProcessRunning
    ) -> GraphExecutor {
        let localWorkflowService = LocalWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: processRunner
        )
        return { graph, workflowBundleURL, binding, runID, runDirectoryURL, routeContext in
            if graph.allNodes.contains(where: { $0.type == .fastqBundleInput }) {
                return try await runNativeWorkflowBuilderGraph(
                    graph: graph,
                    workflowBundleURL: workflowBundleURL,
                    binding: binding,
                    runID: runID,
                    runDirectoryURL: runDirectoryURL,
                    operationCenter: operationCenter,
                    processRunner: processRunner,
                    routeContext: routeContext
                )
            }

            try validateDefaultGraphCanRun(graph)

            let generatedDirectory = runDirectoryURL.appendingPathComponent("generated", isDirectory: true)
            try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
            let generatedWorkflowURL = generatedDirectory.appendingPathComponent("workflow-\(runID.uuidString).nf")
            let script = try NextflowExporter().export(graph: graph)
            try script.write(to: generatedWorkflowURL, atomically: true, encoding: .utf8)

            let outputDirectory = runDirectoryURL.appendingPathComponent("outputs", isDirectory: true)
            let request = LocalWorkflowRunRequest(
                workflowURL: generatedWorkflowURL,
                inputURLs: provenanceInputURLs(for: binding.sample),
                outputDirectory: outputDirectory,
                params: inputParameterBindings(for: graph, binding: binding)
            )
            let result = try await localWorkflowService.run(
                request,
                bundleRoot: runDirectoryURL.appendingPathComponent("local-runs", isDirectory: true),
                routeContext: routeContext
            )
            return GraphExecutionResult(bundleURL: result.bundleURL)
        }
    }

    private static func runNativeWorkflowBuilderGraph(
        graph: WorkflowGraph,
        workflowBundleURL: URL,
        binding: WorkflowBuilderRunBinding,
        runID: UUID,
        runDirectoryURL: URL,
        operationCenter: OperationCenter,
        processRunner: LocalWorkflowCLIProcessRunning,
        routeContext: OperationRouteContext?
    ) async throws -> GraphExecutionResult {
        let arguments = [
            "workflow",
            "builder-run",
            "--workflow",
            workflowBundleURL.standardizedFileURL.path,
            "--project",
            binding.project.path,
            "--run-directory",
            runDirectoryURL.standardizedFileURL.path,
        ]
        let command = (["lungfish-cli"] + arguments).map(shellEscapeForWorkflowBuilder).joined(separator: " ")
        let operationID = operationCenter.start(
            title: "Workflow Builder Runner",
            detail: "Running native Workflow Builder graph",
            operationType: .workflow,
            targetBundleURL: workflowBundleURL,
            cliCommand: command,
            workflowRunID: runID,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: command)

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: runDirectoryURL
            )
            logNativeBuilderProcessOutput(result, operationID: operationID, operationCenter: operationCenter)
            guard result.exitCode == 0 else {
                let message = nativeBuilderFailureMessage(result)
                operationCenter.fail(
                    id: operationID,
                    detail: message,
                    errorMessage: "Workflow Builder runner failed",
                    errorDetail: result.standardError
                )
                throw ExecutionError.nodeFailed(
                    nodeID: nativeBuilderFailureNodeID(in: graph),
                    message: message
                )
            }

            let outputBundleURL = try nativeBuilderOutputBundleURL(
                from: result,
                runDirectoryURL: runDirectoryURL,
                graph: graph
            )
            try verifyNativeBuilderOutputBundle(outputBundleURL, graph: graph)
            operationCenter.complete(
                id: operationID,
                detail: "Workflow Builder runner completed. Output bundle: \(outputBundleURL.path)",
                bundleURLs: [outputBundleURL]
            )
            return GraphExecutionResult(bundleURL: outputBundleURL)
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: errorMessage(forNativeBuilderError: error),
                    errorMessage: "Workflow Builder runner failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }
    }

    private static func nativeBuilderOutputBundleURL(
        from result: LocalWorkflowCLIProcessResult,
        runDirectoryURL: URL,
        graph: WorkflowGraph
    ) throws -> URL {
        let prefix = "Output bundle:"
        for line in result.standardOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            let path = trimmed
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { break }
            let outputBundleURL = URL(fileURLWithPath: path).standardizedFileURL
            try validateNativeBuilderOutputBundleLocation(
                outputBundleURL,
                runDirectoryURL: runDirectoryURL,
                graph: graph
            )
            return outputBundleURL
        }

        let outputDirectory = runDirectoryURL.appendingPathComponent("outputs", isDirectory: true)
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && url.pathExtension.lowercased() == "lungfishfastq"
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard candidates.count == 1 else {
            throw ExecutionError.nodeFailed(
                nodeID: nativeBuilderFailureNodeID(in: graph),
                message: "Workflow Builder runner did not report a single output .lungfishfastq bundle."
            )
        }
        return candidates[0].standardizedFileURL
    }

    private static func validateNativeBuilderOutputBundleLocation(
        _ outputBundleURL: URL,
        runDirectoryURL: URL,
        graph: WorkflowGraph
    ) throws {
        let outputRootPath = runDirectoryURL
            .appendingPathComponent("outputs", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let normalizedRootPath = outputRootPath.hasSuffix("/") ? outputRootPath : outputRootPath + "/"
        let outputPath = outputBundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        guard outputPath.hasPrefix(normalizedRootPath),
              outputBundleURL.pathExtension.lowercased() == "lungfishfastq" else {
            throw ExecutionError.nodeFailed(
                nodeID: nativeBuilderFailureNodeID(in: graph),
                message: "Workflow Builder runner reported an output outside the run outputs directory."
            )
        }
    }

    private static func verifyNativeBuilderOutputBundle(_ outputBundleURL: URL, graph: WorkflowGraph) throws {
        let provenanceURL = outputBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard FileManager.default.fileExists(atPath: provenanceURL.path) else {
            throw ExecutionError.nodeFailed(
                nodeID: nativeBuilderFailureNodeID(in: graph),
                message: "Workflow Builder output bundle is missing \(ProvenanceRecorder.provenanceFilename)."
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let run = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
            guard run.status == .completed,
                  run.steps.contains(where: { $0.toolName == "lungfish-cli workflow builder-run" }),
                  run.allOutputFiles.contains(where: { samePath($0.path, outputBundleURL) || $0.path.hasPrefix(outputBundleURL.path + "/") }) else {
                throw ExecutionError.nodeFailed(
                    nodeID: nativeBuilderFailureNodeID(in: graph),
                    message: "Workflow Builder output provenance is incomplete."
                )
            }
        } catch let executionError as ExecutionError {
            throw executionError
        } catch {
            throw ExecutionError.nodeFailed(
                nodeID: nativeBuilderFailureNodeID(in: graph),
                message: "Workflow Builder output provenance could not be decoded: \(error.localizedDescription)"
            )
        }
    }

    private static func samePath(_ recordedPath: String, _ expectedURL: URL) -> Bool {
        URL(fileURLWithPath: recordedPath).standardizedFileURL.path == expectedURL.standardizedFileURL.path
    }

    private static func logNativeBuilderProcessOutput(
        _ result: LocalWorkflowCLIProcessResult,
        operationID: UUID,
        operationCenter: OperationCenter
    ) {
        for line in result.standardOutput.components(separatedBy: .newlines) where !line.isEmpty {
            operationCenter.log(id: operationID, level: .info, message: line)
        }
        for line in result.standardError.components(separatedBy: .newlines) where !line.isEmpty {
            operationCenter.log(id: operationID, level: .error, message: line)
        }
    }

    private static func nativeBuilderFailureMessage(_ result: LocalWorkflowCLIProcessResult) -> String {
        let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            return "Workflow Builder runner failed with exit code \(result.exitCode): \(detail)"
        }
        return "Workflow Builder runner failed with exit code \(result.exitCode)."
    }

    private static func errorMessage(forNativeBuilderError error: Error) -> String {
        if case ExecutionError.nodeFailed(_, let message) = error {
            return message
        }
        return error.localizedDescription
    }

    private static func nativeBuilderFailureNodeID(in graph: WorkflowGraph) -> UUID {
        graph.allNodes.first { $0.type == .fastqBundleInput }?.id
            ?? graph.allNodes.first?.id
            ?? UUID()
    }

    private static func validateDefaultGraphCanRun(_ graph: WorkflowGraph) throws {
        for node in graph.nodes.values where node.type.category == .input && node.type != .fastqInput && node.type != .sampleInput {
            throw ExecutionError.nodeFailed(
                nodeID: node.id,
                message: "Unsupported Workflow Builder input node '\(node.label)' (\(node.type.displayName)). Production runs currently bind only FASTQ Input nodes to the selected sample; refusing to mark this node successful without executable work and provenance."
            )
        }
    }

    private static func inputParameterBindings(
        for graph: WorkflowGraph,
        binding: WorkflowBuilderRunBinding
    ) -> [String: String] {
        graph.nodes.values
            .filter { $0.type == .fastqInput || $0.type == .sampleInput }
            .reduce(into: [:]) { params, node in
                params[sanitizeNextflowIdentifier(node.label)] = binding.sample.path
            }
    }

    private static func provenanceInputURLs(for sample: LocalWorkflowInputBinding) -> [URL] {
        let sampleURL = URL(fileURLWithPath: sample.path).standardizedFileURL
        var urls = [sampleURL]
        guard let enumerator = FileManager.default.enumerator(
            at: sampleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return urls
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                urls.append(url.standardizedFileURL)
            }
        }
        return urls
    }

    private static func sanitizeNextflowIdentifier(_ name: String) -> String {
        var sanitized = name.replacingOccurrences(of: " ", with: "_")
        sanitized = sanitized.replacingOccurrences(of: "-", with: "_")
        sanitized = sanitized.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if let first = sanitized.first, first.isNumber {
            sanitized = "_" + sanitized
        }
        return sanitized.lowercased()
    }

    private func makeInitialRecord(
        runID: UUID,
        graph: WorkflowGraph,
        workflowBundleURL: URL,
        graphChecksum: String,
        binding: WorkflowBuilderRunBinding,
        nodes: [WorkflowNode],
        startedAt: Date,
        argv: [String],
        runDirectoryURL: URL
    ) -> WorkflowBuilderRunRecord {
        WorkflowBuilderRunRecord(
            id: runID,
            workflowName: graph.name,
            workflowBundleURL: workflowBundleURL,
            graph: graph,
            graphChecksumSHA256: graphChecksum,
            binding: binding,
            status: .running,
            startedAt: startedAt,
            nodeRecords: nodes.map { WorkflowBuilderNodeRunRecord(node: $0) },
            provenance: WorkflowBuilderRunProvenance(
                toolName: "Lungfish Workflow Builder",
                argv: argv,
                command: argv.map(shellEscapeForWorkflowBuilder).joined(separator: " "),
                options: [
                    "sample": binding.sample.path,
                    "project": binding.project.path,
                    "runID": runID.uuidString,
                ],
                resolvedDefaults: [
                    "nodeDispatch": "operation-center",
                    "failurePolicy": "stop-on-first-failing-node",
                ],
                inputs: [
                    binding.sample,
                    LocalWorkflowInputBinding(url: workflowBundleURL.appendingPathComponent("graph.json"), role: .input),
                ],
                outputs: [
                    binding.project,
                    LocalWorkflowInputBinding(url: runDirectoryURL, role: .output),
                ]
            )
        )
    }

    private func setNodeStatus(
        _ nodeID: UUID,
        in record: inout WorkflowBuilderRunRecord,
        status: WorkflowBuilderNodeRunStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = record.nodeRecords.firstIndex(where: { $0.nodeID == nodeID }) else { return }
        record.nodeRecords[index].status = status
        if let startedAt {
            record.nodeRecords[index].startedAt = startedAt
        }
        if let completedAt {
            record.nodeRecords[index].completedAt = completedAt
        }
        record.nodeRecords[index].errorMessage = errorMessage
    }

    private func markPendingNodesSkipped(in record: inout WorkflowBuilderRunRecord) {
        for index in record.nodeRecords.indices where record.nodeRecords[index].status == .pending {
            record.nodeRecords[index].status = .skipped
            record.nodeRecords[index].completedAt = Date()
        }
    }

    private func markUnfinishedNodesSkipped(in record: inout WorkflowBuilderRunRecord, except failedNodeID: UUID?) {
        for index in record.nodeRecords.indices where record.nodeRecords[index].nodeID != failedNodeID {
            switch record.nodeRecords[index].status {
            case .pending, .running:
                record.nodeRecords[index].status = .skipped
                record.nodeRecords[index].completedAt = Date()
            case .succeeded, .failed, .skipped:
                break
            }
        }
    }

    private func failingNodeID(from error: Error) -> UUID? {
        if case ExecutionError.nodeFailed(let nodeID, _) = error {
            return nodeID
        }
        return nil
    }

    private func errorMessage(for error: Error) -> String {
        if case ExecutionError.nodeFailed(_, let message) = error {
            return message
        }
        return error.localizedDescription
    }

    private func normalizedNodeFailure(_ error: Error, node: WorkflowNode, message: String) -> ExecutionError {
        if let executionError = error as? ExecutionError {
            return executionError
        }
        return .nodeFailed(nodeID: node.id, message: message)
    }
}

private func shellEscapeForWorkflowBuilder(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
