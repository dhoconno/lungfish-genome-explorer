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

    private let operationCenter: OperationCenter
    private let nodeExecutor: NodeExecutor

    public init(
        operationCenter: OperationCenter = .shared,
        nodeExecutor: @escaping NodeExecutor = { _, _ in }
    ) {
        self.operationCenter = operationCenter
        self.nodeExecutor = nodeExecutor
    }

    public func run(
        graph: WorkflowGraph,
        workflowBundleURL: URL,
        binding: WorkflowBuilderRunBinding
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
            workflowRunID: runID
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

        for (index, node) in sortedNodes.enumerated() {
            let nodeOperationID = operationCenter.start(
                title: node.label,
                detail: "Running workflow node",
                operationType: .workflow,
                targetBundleURL: workflowBundleURL,
                cliCommand: argv.map(shellEscapeForWorkflowBuilder).joined(separator: " "),
                workflowRunID: runID
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

        record.status = .succeeded
        record.completedAt = Date()
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
