import Foundation
import LungfishIO

public struct ProjectStorageCleanupInventoryEntry:
    Codable,
    Equatable,
    Sendable
{
    public let relativePath: String
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let sha256: String
    public let device: UInt64
    public let inode: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(
        relativePath: String,
        logicalSize: UInt64,
        allocatedSize: UInt64,
        sha256: String,
        device: UInt64,
        inode: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        changedSeconds: Int64,
        changedNanoseconds: Int64
    ) {
        self.relativePath = relativePath
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.sha256 = sha256
        self.device = device
        self.inode = inode
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }

    func parameterValue() -> ParameterValue {
        .dictionary([
            "allocatedSize": exactCleanupParameterValue(allocatedSize),
            "changedNanoseconds": exactCleanupParameterValue(
                changedNanoseconds
            ),
            "changedSeconds": exactCleanupParameterValue(changedSeconds),
            "device": exactCleanupParameterValue(device),
            "inode": exactCleanupParameterValue(inode),
            "logicalSize": exactCleanupParameterValue(logicalSize),
            "modifiedNanoseconds": exactCleanupParameterValue(
                modifiedNanoseconds
            ),
            "modifiedSeconds": exactCleanupParameterValue(modifiedSeconds),
            "relativePath": .string(relativePath),
            "sha256": .string(sha256),
        ])
    }
}

public struct ProjectStorageCleanupAttestedInventory: Equatable, Sendable {
    public let sourceRelativePath: String
    public let sourceIdentity: FileSystemObjectIdentity
    public let sourceProvenancePath: String
    public let sourceProvenanceChecksumSHA256: String
    public let sourceProvenanceFileSize: UInt64
    public let entries: [ProjectStorageCleanupInventoryEntry]

    public init(
        sourceRelativePath: String,
        sourceIdentity: FileSystemObjectIdentity,
        sourceProvenancePath: String,
        sourceProvenanceChecksumSHA256: String,
        sourceProvenanceFileSize: UInt64,
        entries: [ProjectStorageCleanupInventoryEntry]
    ) {
        self.sourceRelativePath = sourceRelativePath
        self.sourceIdentity = sourceIdentity
        self.sourceProvenancePath = sourceProvenancePath
        self.sourceProvenanceChecksumSHA256 =
            sourceProvenanceChecksumSHA256
        self.sourceProvenanceFileSize = sourceProvenanceFileSize
        self.entries = entries
    }
}

public struct ProjectStorageCleanupJournal: Codable, Equatable, Sendable {
    public struct AttestationSource: Codable, Equatable, Sendable {
        public let sourceRelativePath: String
        public let sourceIdentity: FileSystemObjectIdentity
        public let provenancePath: String
        public let provenanceChecksumSHA256: String
        public let provenanceFileSize: UInt64

        init(_ inventory: ProjectStorageCleanupAttestedInventory) {
            sourceRelativePath = inventory.sourceRelativePath
            sourceIdentity = inventory.sourceIdentity
            provenancePath = inventory.sourceProvenancePath
            provenanceChecksumSHA256 =
                inventory.sourceProvenanceChecksumSHA256
            provenanceFileSize = inventory.sourceProvenanceFileSize
        }
    }

    public enum IntendedAction: String, Codable, Equatable, Sendable {
        case moveToTrash = "move-to-trash"
    }

    public enum State: String, Codable, Equatable, Sendable {
        case prepared
        case executing
        case completed
        case completedWithFailures = "completed-with-failures"
        case failed
    }

    public struct Item: Codable, Equatable, Sendable {
        public enum State: String, Codable, Equatable, Sendable {
            case prepared
            case detached
            case movedToTrash = "moved-to-trash"
            case skipped
            case failed
        }

        public let id: UUID
        public let sourceRelativePath: String
        public let sourceIdentity: FileSystemObjectIdentity
        public let sourceCategory: ProjectStorageEntry.Category
        public let classification: ProjectStorageClassification
        public let classificationEvidenceDigest: String
        public let inventory: [ProjectStorageCleanupInventoryEntry]
        public let aggregateTreeDigest: String
        public let intendedAction: IntendedAction
        public let state: State
        public let quarantineRelativePath: String?
        public let trashDestinationPath: String?
        public let error: String?

        public init(
            id: UUID,
            sourceRelativePath: String,
            sourceIdentity: FileSystemObjectIdentity,
            sourceCategory: ProjectStorageEntry.Category,
            classification: ProjectStorageClassification,
            classificationEvidenceDigest: String,
            inventory: [ProjectStorageCleanupInventoryEntry],
            aggregateTreeDigest: String,
            intendedAction: IntendedAction = .moveToTrash,
            state: State = .prepared,
            quarantineRelativePath: String? = nil,
            trashDestinationPath: String? = nil,
            error: String? = nil
        ) {
            self.id = id
            self.sourceRelativePath = sourceRelativePath
            self.sourceIdentity = sourceIdentity
            self.sourceCategory = sourceCategory
            self.classification = classification
            self.classificationEvidenceDigest =
                classificationEvidenceDigest
            self.inventory = inventory
            self.aggregateTreeDigest = aggregateTreeDigest
            self.intendedAction = intendedAction
            self.state = state
            self.quarantineRelativePath = quarantineRelativePath
            self.trashDestinationPath = trashDestinationPath
            self.error = error
        }

        func parameterValue() -> ParameterValue {
            .dictionary([
                "aggregateTreeDigest": .string(aggregateTreeDigest),
                "classificationCode": .string(classification.code.rawValue),
                "classificationEvidenceDigest":
                    .string(classificationEvidenceDigest),
                "intendedAction": .string(intendedAction.rawValue),
                "inventory": .array(
                    inventory.map { $0.parameterValue() }
                ),
                "sourceCategory": .string(sourceCategory.rawValue),
                "sourceDevice": exactCleanupParameterValue(
                    sourceIdentity.device
                ),
                "sourceInode": exactCleanupParameterValue(
                    sourceIdentity.inode
                ),
                "sourceRelativePath": .string(sourceRelativePath),
            ])
        }
    }

    public let schemaVersion: Int
    public let cleanupID: UUID
    public let projectRoot: String
    public let projectIdentity: FileSystemObjectIdentity
    public let intendedAction: IntendedAction
    public let state: State
    public let startedAt: Date
    public let completedAt: Date
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let reproducibleCommand: String
    public let options: ProvenanceOptions
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let attestationSources: [AttestationSource]
    public let items: [Item]
    public let exitStatus: Int
    public let wallTimeSeconds: TimeInterval
    public let stderr: String
    public let provenanceFileName: String

    public init(
        schemaVersion: Int = 1,
        cleanupID: UUID,
        projectRoot: String,
        projectIdentity: FileSystemObjectIdentity,
        intendedAction: IntendedAction = .moveToTrash,
        state: State = .prepared,
        startedAt: Date,
        completedAt: Date,
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String,
        argv: [String],
        durableReplayArgv: [String]?,
        reproducibleCommand: String,
        options: ProvenanceOptions,
        runtimeIdentity: ProvenanceRuntimeIdentity,
        attestationSources: [AttestationSource] = [],
        items: [Item],
        exitStatus: Int,
        wallTimeSeconds: TimeInterval,
        stderr: String,
        provenanceFileName: String = "provenance.json"
    ) {
        self.schemaVersion = schemaVersion
        self.cleanupID = cleanupID
        self.projectRoot = projectRoot
        self.projectIdentity = projectIdentity
        self.intendedAction = intendedAction
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.reproducibleCommand = reproducibleCommand
        self.options = options
        self.runtimeIdentity = runtimeIdentity
        self.attestationSources = attestationSources
        self.items = items
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
        self.provenanceFileName = provenanceFileName
    }

    func inventoryParameterValue() -> ParameterValue {
        .array(items.map { $0.parameterValue() })
    }
}

public struct ProjectStorageCleanupPreparationRequest: Sendable {
    public let cleanupID: UUID
    public let projectURL: URL
    public let projectIdentity: FileSystemObjectIdentity
    public let selectedEntries: [ProjectStorageEntry]
    public let attestedInventories:
        [ProjectStorageCleanupAttestedInventory]
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let options: ProvenanceOptions
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let startedAt: Date

    public init(
        cleanupID: UUID = UUID(),
        projectURL: URL,
        projectIdentity: FileSystemObjectIdentity,
        selectedEntries: [ProjectStorageEntry],
        attestedInventories:
            [ProjectStorageCleanupAttestedInventory] = [],
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        options: ProvenanceOptions,
        runtimeIdentity: ProvenanceRuntimeIdentity,
        startedAt: Date = Date()
    ) {
        self.cleanupID = cleanupID
        self.projectURL = projectURL.standardizedFileURL
        self.projectIdentity = projectIdentity
        self.selectedEntries = selectedEntries
        self.attestedInventories = attestedInventories
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.options = options
        self.runtimeIdentity = runtimeIdentity
        self.startedAt = startedAt
    }
}

func exactCleanupParameterValue<T: BinaryInteger>(
    _ value: T
) -> ParameterValue {
    if let integer = Int(exactly: value) {
        return .integer(integer)
    }
    return .string(String(value))
}

public struct ProjectStorageCleanupPreparation: Sendable {
    public let operationDirectoryURL: URL
    public let operationDirectoryIdentity: FileSystemObjectIdentity
    public let journalURL: URL
    public let provenanceURL: URL
    public let journal: ProjectStorageCleanupJournal
    public let provenance: ProvenanceEnvelope

    public init(
        operationDirectoryURL: URL,
        operationDirectoryIdentity: FileSystemObjectIdentity,
        journalURL: URL,
        provenanceURL: URL,
        journal: ProjectStorageCleanupJournal,
        provenance: ProvenanceEnvelope
    ) {
        self.operationDirectoryURL = operationDirectoryURL
        self.operationDirectoryIdentity = operationDirectoryIdentity
        self.journalURL = journalURL
        self.provenanceURL = provenanceURL
        self.journal = journal
        self.provenance = provenance
    }
}
