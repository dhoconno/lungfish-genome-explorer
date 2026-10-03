import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct ProjectStorageCleanupExecutionSummary:
    Codable,
    Equatable,
    Sendable
{
    public enum State: String, Codable, Equatable, Sendable {
        case completed
        case completedWithFailures = "completed-with-failures"
        case failed
    }

    public struct Item: Codable, Equatable, Sendable {
        public let itemID: UUID
        public let sourceRelativePath: String
        public let state: ProjectStorageCleanupDispositionRecord.State
        public let quarantineRelativePath: String?
        public let trashDestinationPath: String?
        public let reason: String?

        public init(
            itemID: UUID,
            sourceRelativePath: String,
            state: ProjectStorageCleanupDispositionRecord.State,
            quarantineRelativePath: String?,
            trashDestinationPath: String?,
            reason: String?
        ) {
            self.itemID = itemID
            self.sourceRelativePath = sourceRelativePath
            self.state = state
            self.quarantineRelativePath = quarantineRelativePath
            self.trashDestinationPath = trashDestinationPath
            self.reason = reason
        }
    }

    public let schemaVersion: Int
    public let cleanupID: UUID
    public let projectRoot: String
    public let projectIdentity: FileSystemObjectIdentity
    public let state: State
    public let items: [Item]
    public let startedAt: Date
    public let completedAt: Date
    public let exitStatus: Int
    public let wallTimeSeconds: TimeInterval
    public let stderr: String

    public init(
        schemaVersion: Int = 1,
        cleanupID: UUID,
        projectRoot: String,
        projectIdentity: FileSystemObjectIdentity,
        state: State,
        items: [Item],
        startedAt: Date,
        completedAt: Date,
        exitStatus: Int,
        wallTimeSeconds: TimeInterval,
        stderr: String
    ) {
        self.schemaVersion = schemaVersion
        self.cleanupID = cleanupID
        self.projectRoot = projectRoot
        self.projectIdentity = projectIdentity
        self.state = state
        self.items = items
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
    }
}
