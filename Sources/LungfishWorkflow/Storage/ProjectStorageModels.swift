import CryptoKit
import Foundation
import LungfishIO

public struct ProjectStorageClassification: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Equatable, Sendable {
        case removable
        case notRemovable
    }

    public enum Code: String, Codable, Equatable, Sendable {
        case completedOwnedWork
        case conclusivelyOrphanedOwnedWork
        case retainedWorkbookRevision
        case missingOwnershipMarker
        case invalidOwnershipMarker
        case explicitlyRetained
        case liveProcess
        case heldLock
        case unsafeLock
        case liveOperationHistory
        case unsafeFileSystemObject
        case identityChanged
        case ambiguousWorkbookArchive
        case liveWorkbookAuthority
        case unknownOwnedPattern
        case inspectionFailed
        case resourceLimitExceeded
    }

    public let disposition: Disposition
    public let code: Code
    public let reason: String

    public var isRemovable: Bool { disposition == .removable }

    public static func removable(
        _ code: Code,
        reason: String
    ) -> Self {
        Self(
            disposition: .removable,
            code: code,
            reason: reason
        )
    }

    public static func notRemovable(
        _ code: Code,
        reason: String
    ) -> Self {
        Self(
            disposition: .notRemovable,
            code: code,
            reason: reason
        )
    }
}

public struct ProjectStorageEntry: Identifiable, Equatable, Sendable {
    public enum Category: String, Codable, Equatable, Sendable {
        case workbookArchive
        case workflowStaging
        case temporary
    }

    public let id: UUID
    public let relativePath: String
    public let identity: FileSystemObjectIdentity
    public let category: Category
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let modificationDate: Date
    public let classification: ProjectStorageClassification

    public init(
        projectIdentity: FileSystemObjectIdentity,
        relativePath: String,
        identity: FileSystemObjectIdentity,
        category: Category,
        logicalBytes: UInt64,
        allocatedBytes: UInt64,
        modificationDate: Date,
        classification: ProjectStorageClassification
    ) {
        self.id = Self.stableID(
            projectIdentity: projectIdentity,
            relativePath: relativePath
        )
        self.relativePath = relativePath
        self.identity = identity
        self.category = category
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.modificationDate = modificationDate
        self.classification = classification
    }

    private static func stableID(
        projectIdentity: FileSystemObjectIdentity,
        relativePath: String
    ) -> UUID {
        var bytes = Array(
            SHA256.hash(
                data: Data(
                    "\(projectIdentity.device):\(projectIdentity.inode):"
                        .appending(relativePath).utf8
                )
            ).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct ProjectStorageScanProgress: Equatable, Sendable {
    public let visitedFileSystemObjects: UInt64
    public let classifiedEntries: UInt64
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let currentRelativePath: String

    public init(
        visitedFileSystemObjects: UInt64,
        classifiedEntries: UInt64,
        logicalBytes: UInt64,
        allocatedBytes: UInt64,
        currentRelativePath: String
    ) {
        self.visitedFileSystemObjects = visitedFileSystemObjects
        self.classifiedEntries = classifiedEntries
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.currentRelativePath = currentRelativePath
    }
}

public struct ProjectStorageScanResult: Equatable, Sendable {
    public let projectIdentity: FileSystemObjectIdentity
    public let entries: [ProjectStorageEntry]

    public var reclaimableLogicalBytes: UInt64 {
        Self.reclaimableTotal(entries, keyPath: \.logicalBytes)
    }

    public var reclaimableAllocatedBytes: UInt64 {
        Self.reclaimableTotal(entries, keyPath: \.allocatedBytes)
    }

    public init(
        projectIdentity: FileSystemObjectIdentity,
        entries: [ProjectStorageEntry]
    ) {
        self.projectIdentity = projectIdentity
        self.entries = entries
    }

    private static func reclaimableTotal(
        _ entries: [ProjectStorageEntry],
        keyPath: KeyPath<ProjectStorageEntry, UInt64>
    ) -> UInt64 {
        var total: UInt64 = 0
        for entry in entries where entry.classification.isRemovable {
            let (sum, overflow) = total.addingReportingOverflow(
                entry[keyPath: keyPath]
            )
            if overflow { return .max }
            total = sum
        }
        return total
    }
}
