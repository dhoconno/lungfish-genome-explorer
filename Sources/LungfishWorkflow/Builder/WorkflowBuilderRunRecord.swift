import CryptoKit
import Foundation

public enum WorkflowBuilderRunStatus: String, Codable, Sendable, Equatable {
    case running
    case succeeded
    case failed
}

public enum WorkflowBuilderNodeRunStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

public struct WorkflowBuilderRunBinding: Codable, Sendable, Equatable {
    public let sample: LocalWorkflowInputBinding
    public let project: LocalWorkflowInputBinding

    public init(sampleURL: URL, projectURL: URL) {
        self.sample = LocalWorkflowInputBinding(url: sampleURL, role: .input)
        self.project = LocalWorkflowInputBinding(url: projectURL, role: .output)
    }
}

public struct WorkflowBuilderNodeRunRecord: Codable, Sendable, Equatable, Identifiable {
    public let nodeID: UUID
    public let nodeType: WorkflowNodeType
    public let label: String
    public var status: WorkflowBuilderNodeRunStatus
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?

    public var id: UUID { nodeID }

    public init(
        node: WorkflowNode,
        status: WorkflowBuilderNodeRunStatus = .pending,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.nodeID = node.id
        self.nodeType = node.type
        self.label = node.label
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

public struct WorkflowBuilderRunProvenance: Codable, Sendable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let command: String
    public let options: [String: String]
    public let resolvedDefaults: [String: String]
    public let runtimeIdentity: WorkflowRuntime
    public let inputs: [LocalWorkflowInputBinding]
    public let outputs: [LocalWorkflowInputBinding]
    public var exitStatus: Int32?
    public var wallTimeSeconds: TimeInterval?
    public var stderr: String?

    public init(
        toolName: String,
        toolVersion: String = WorkflowRun.currentAppVersion,
        argv: [String],
        command: String,
        options: [String: String],
        resolvedDefaults: [String: String],
        runtimeIdentity: WorkflowRuntime = WorkflowRuntime(
            appVersion: WorkflowRun.currentAppVersion,
            hostOS: WorkflowRun.currentHostOS,
            user: WorkflowRun.currentUser
        ),
        inputs: [LocalWorkflowInputBinding],
        outputs: [LocalWorkflowInputBinding],
        exitStatus: Int32? = nil,
        wallTimeSeconds: TimeInterval? = nil,
        stderr: String? = nil
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.command = command
        self.options = options
        self.resolvedDefaults = resolvedDefaults
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
    }
}

public struct WorkflowBuilderRunRecord: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let workflowName: String
    public let workflowBundlePath: String
    public let graphID: UUID
    public let graphChecksumSHA256: String
    public let binding: WorkflowBuilderRunBinding
    public var status: WorkflowBuilderRunStatus
    public let startedAt: Date
    public var completedAt: Date?
    public var nodeRecords: [WorkflowBuilderNodeRunRecord]
    public var errorMessage: String?
    public var provenance: WorkflowBuilderRunProvenance

    public init(
        id: UUID,
        workflowName: String,
        workflowBundleURL: URL,
        graph: WorkflowGraph,
        graphChecksumSHA256: String,
        binding: WorkflowBuilderRunBinding,
        status: WorkflowBuilderRunStatus,
        startedAt: Date,
        completedAt: Date? = nil,
        nodeRecords: [WorkflowBuilderNodeRunRecord],
        errorMessage: String? = nil,
        provenance: WorkflowBuilderRunProvenance
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.workflowName = workflowName
        self.workflowBundlePath = workflowBundleURL.standardizedFileURL.path
        self.graphID = graph.id
        self.graphChecksumSHA256 = graphChecksumSHA256
        self.binding = binding
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.nodeRecords = nodeRecords
        self.errorMessage = errorMessage
        self.provenance = provenance
    }
}

public enum WorkflowBuilderRunStore {
    public static let runsDirectoryName = "runs"
    public static let runRecordFilename = "run.json"
    public static let provenanceFilename = "provenance.json"

    public static func runDirectory(runID: UUID, in workflowBundleURL: URL) -> URL {
        workflowBundleURL
            .appendingPathComponent(runsDirectoryName, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    public static func write(_ record: WorkflowBuilderRunRecord, to workflowBundleURL: URL) throws {
        let runDirectory = runDirectory(runID: record.id, in: workflowBundleURL)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: runDirectory.appendingPathComponent(runRecordFilename), options: .atomic)
        try encoder.encode(record.provenance).write(
            to: runDirectory.appendingPathComponent(provenanceFilename),
            options: .atomic
        )
    }

    public static func readRun(runID: UUID, from workflowBundleURL: URL) throws -> WorkflowBuilderRunRecord {
        let url = runDirectory(runID: runID, in: workflowBundleURL).appendingPathComponent(runRecordFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowBuilderRunRecord.self, from: Data(contentsOf: url))
    }

    public static func graphChecksum(for graph: WorkflowGraph) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(graph)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
