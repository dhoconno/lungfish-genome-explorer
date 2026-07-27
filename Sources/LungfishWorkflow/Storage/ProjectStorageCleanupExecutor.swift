import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct ProjectStorageCleanupExecutionRequest: Sendable {
    public let projectURL: URL
    public let cleanupID: UUID
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let options: ProvenanceOptions
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let startedAt: Date

    public init(
        projectURL: URL,
        cleanupID: UUID,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        options: ProvenanceOptions,
        runtimeIdentity: ProvenanceRuntimeIdentity,
        startedAt: Date = Date()
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.cleanupID = cleanupID
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.options = options
        self.runtimeIdentity = runtimeIdentity
        self.startedAt = startedAt
    }
}

public struct ProjectStorageCleanupDispositionRecord:
    Codable,
    Equatable,
    Sendable
{
    public enum State: String, Codable, Equatable, Sendable {
        case detachIntent = "detach-intent"
        case detached
        case trashIntent = "trash-intent"
        case trashFailed = "trash-failed"
        case movedToTrash = "moved-to-trash"
        case restoredAfterTrashFailure = "restored-after-trash-failure"
        case quarantineRetained = "quarantine-retained"
        case skipped
        case failed
        case outcomeUnknown = "outcome-unknown"

        var isTerminal: Bool {
            switch self {
            case .detachIntent, .detached, .trashIntent, .trashFailed:
                return false
            default:
                return true
            }
        }
    }

    public let schemaVersion: Int
    public let cleanupID: UUID
    public let projectIdentity: FileSystemObjectIdentity
    public let itemID: UUID
    public let sourceRelativePath: String
    public let sourceIdentity: FileSystemObjectIdentity
    public let state: State
    public let quarantineRelativePath: String?
    public let quarantineIdentity: FileSystemObjectIdentity?
    public let trashDestinationPath: String?
    public let reason: String?
    public let recordedAt: Date
    public let integritySHA256: String

    public init(
        schemaVersion: Int = 1,
        cleanupID: UUID,
        projectIdentity: FileSystemObjectIdentity,
        itemID: UUID,
        sourceRelativePath: String,
        sourceIdentity: FileSystemObjectIdentity,
        state: State,
        quarantineRelativePath: String? = nil,
        quarantineIdentity: FileSystemObjectIdentity? = nil,
        trashDestinationPath: String? = nil,
        reason: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.cleanupID = cleanupID
        self.projectIdentity = projectIdentity
        self.itemID = itemID
        self.sourceRelativePath = sourceRelativePath
        self.sourceIdentity = sourceIdentity
        self.state = state
        self.quarantineRelativePath = quarantineRelativePath
        self.quarantineIdentity = quarantineIdentity
        self.trashDestinationPath = trashDestinationPath
        self.reason = reason
        self.recordedAt = recordedAt
        self.integritySHA256 = Self.integrityDigest(
            schemaVersion: schemaVersion,
            cleanupID: cleanupID,
            projectIdentity: projectIdentity,
            itemID: itemID,
            sourceRelativePath: sourceRelativePath,
            sourceIdentity: sourceIdentity,
            state: state,
            quarantineRelativePath: quarantineRelativePath,
            quarantineIdentity: quarantineIdentity,
            trashDestinationPath: trashDestinationPath,
            reason: reason,
            recordedAt: recordedAt
        )
    }

    fileprivate var hasValidIntegrity: Bool {
        integritySHA256 == Self.integrityDigest(
            schemaVersion: schemaVersion,
            cleanupID: cleanupID,
            projectIdentity: projectIdentity,
            itemID: itemID,
            sourceRelativePath: sourceRelativePath,
            sourceIdentity: sourceIdentity,
            state: state,
            quarantineRelativePath: quarantineRelativePath,
            quarantineIdentity: quarantineIdentity,
            trashDestinationPath: trashDestinationPath,
            reason: reason,
            recordedAt: recordedAt
        )
    }

    private struct IntegrityPayload: Encodable {
        let schemaVersion: Int
        let cleanupID: UUID
        let projectIdentity: FileSystemObjectIdentity
        let itemID: UUID
        let sourceRelativePath: String
        let sourceIdentity: FileSystemObjectIdentity
        let state: State
        let quarantineRelativePath: String?
        let quarantineIdentity: FileSystemObjectIdentity?
        let trashDestinationPath: String?
        let reason: String?
        let recordedAt: Date
    }

    private static func integrityDigest(
        schemaVersion: Int,
        cleanupID: UUID,
        projectIdentity: FileSystemObjectIdentity,
        itemID: UUID,
        sourceRelativePath: String,
        sourceIdentity: FileSystemObjectIdentity,
        state: State,
        quarantineRelativePath: String?,
        quarantineIdentity: FileSystemObjectIdentity?,
        trashDestinationPath: String?,
        reason: String?,
        recordedAt: Date
    ) -> String {
        let payload = IntegrityPayload(
            schemaVersion: schemaVersion,
            cleanupID: cleanupID,
            projectIdentity: projectIdentity,
            itemID: itemID,
            sourceRelativePath: sourceRelativePath,
            sourceIdentity: sourceIdentity,
            state: state,
            quarantineRelativePath: quarantineRelativePath,
            quarantineIdentity: quarantineIdentity,
            trashDestinationPath: trashDestinationPath,
            reason: reason,
            recordedAt: recordedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

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

public struct ProjectStorageCleanupExecutionResult: Sendable {
    public let summary: ProjectStorageCleanupExecutionSummary
    public let summaryURL: URL
    public let provenanceURL: URL
}

public enum ProjectStorageCleanupExecutionError: Error, LocalizedError {
    case unsafeAuthority(String)
    case stateCorrupt(String)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafeAuthority(let reason):
            return "Project storage cleanup authority is unsafe: \(reason)"
        case .stateCorrupt(let reason):
            return "Project storage cleanup state is unsafe: \(reason)"
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}

public struct ProjectStorageCleanupExecutor: Sendable {
    public static let stateFileName = "execution-state.jsonl"

    enum PreparationFileRole: Sendable {
        case journal
        case provenance
    }

    enum Checkpoint: Sendable, Equatable {
        case afterDispositionWriteBeforeFileSync
        case afterDispositionFileSyncBeforeDirectorySync
        case afterDispositionDurable
        case afterDetachIntentBeforeRename
        case afterDetachBeforeParentSync
        case afterDetachBeforeRecord
        case afterDetachParentSyncBeforeRecord
        case afterDetachedRecordBeforeTrashIntent
        case afterTrashIntentBeforeTrash
        case afterTrashBeforeRecord
        case afterTrashFailureBeforeRestore
        case afterRestoreBeforeParentSync
        case afterRestoreBeforeRecord
        case afterRestoreParentSyncBeforeRecord
        case afterQuarantineRetainedBeforeRecord
        case afterItemTerminalBeforeNext
        case afterSummaryWriteBeforeFileSync
        case afterSummaryFileSyncBeforeDirectorySync
        case afterSummaryDirectorySyncBeforeDurable
        case afterSummaryDurable
        case afterProvenanceWriteBeforeFileSync
        case afterProvenanceFileSyncBeforeDirectorySync
        case afterProvenanceDirectorySyncBeforeDurable
        case afterProvenanceDurable
    }

    struct Operations: @unchecked Sendable {
        var cancellationCheck: () throws -> Void
        var acquireAssociatedLock:
            (
                URL,
                FileSystemObjectIdentity,
                UUID
            ) throws -> (() -> Void)
        var authoritativeScan:
            (URL) throws -> ProjectStorageScanResult
        var afterReadPreparationFile:
            (PreparationFileRole) throws -> Void
        var afterAuthorityVerified:
            (ProjectStorageCleanupJournal.Item) throws -> Void
        var beforeAppendDisposition:
            (ProjectStorageCleanupDispositionRecord) throws -> Void
        var didOpenStateLog: (Int32) -> Void
        var renameExclusive:
            (Int32, String, Int32, String, UInt32) -> Int32
        var syncFile: (Int32) -> Int32
        var syncDirectory: (Int32) -> Int32
        var trashItem: (URL) throws -> URL
        var checkpoint: (Checkpoint, UUID) throws -> Void
        var now: () -> Date

        init(
            cancellationCheck:
                @escaping () throws -> Void = {
                    try Task.checkCancellation()
                },
            acquireAssociatedLock:
                @escaping (
                    URL,
                    FileSystemObjectIdentity,
                    UUID
                ) throws -> (() -> Void) = { _, _, _ in {} },
            authoritativeScan:
                @escaping (URL) throws
                    -> ProjectStorageScanResult = {
                        try ProjectStorageScanner().scan(projectURL: $0)
                    },
            afterReadPreparationFile:
                @escaping (PreparationFileRole) throws -> Void = {
                    _ in
                },
            afterAuthorityVerified:
                @escaping (
                    ProjectStorageCleanupJournal.Item
                ) throws -> Void = { _ in },
            beforeAppendDisposition:
                @escaping (
                    ProjectStorageCleanupDispositionRecord
                ) throws -> Void = { _ in },
            didOpenStateLog:
                @escaping (Int32) -> Void = { _ in },
            renameExclusive:
                @escaping (
                    Int32,
                    String,
                    Int32,
                    String,
                    UInt32
                ) -> Int32 = { sourceParent, source, destinationParent,
                    destination, flags in
                    source.withCString { sourcePointer in
                        destination.withCString { destinationPointer in
                            Darwin.renameatx_np(
                                sourceParent,
                                sourcePointer,
                                destinationParent,
                                destinationPointer,
                                flags
                            )
                        }
                    }
                },
            syncFile:
                @escaping (Int32) -> Int32 = { Darwin.fsync($0) },
            syncDirectory:
                @escaping (Int32) -> Int32 = {
                    Darwin.fsync($0)
                },
            trashItem:
                @escaping (URL) throws -> URL = {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(
                        at: $0,
                        resultingItemURL: &resultingURL
                    )
                    guard let resultingURL else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    return resultingURL as URL
                },
            checkpoint:
                @escaping (Checkpoint, UUID) throws -> Void = {
                    _, _ in
                },
            now: @escaping () -> Date = { Date() }
        ) {
            self.cancellationCheck = cancellationCheck
            self.acquireAssociatedLock = acquireAssociatedLock
            self.authoritativeScan = authoritativeScan
            self.afterReadPreparationFile = afterReadPreparationFile
            self.afterAuthorityVerified = afterAuthorityVerified
            self.beforeAppendDisposition = beforeAppendDisposition
            self.didOpenStateLog = didOpenStateLog
            self.renameExclusive = renameExclusive
            self.syncFile = syncFile
            self.syncDirectory = syncDirectory
            self.trashItem = trashItem
            self.checkpoint = checkpoint
            self.now = now
        }

        init(
            beforeAppendDisposition:
                @escaping (ProjectStorageCleanupDispositionRecord) throws
                    -> Void,
            syncFile: @escaping (Int32) -> Int32,
            syncDirectory: @escaping (Int32) -> Int32,
            renameExclusive:
                @escaping (Int32, String, Int32, String, UInt32) -> Int32,
            checkpoint:
                @escaping (Checkpoint, UUID) throws -> Void = { _, _ in }
        ) {
            self.init(
                beforeAppendDisposition: beforeAppendDisposition,
                renameExclusive: renameExclusive,
                syncFile: syncFile,
                syncDirectory: syncDirectory,
                checkpoint: checkpoint
            )
        }

        init(
            cancellationCheck: @escaping () throws -> Void,
            acquireAssociatedLock:
                @escaping (
                    URL,
                    FileSystemObjectIdentity,
                    UUID
                ) throws -> (() -> Void),
            authoritativeScan:
                @escaping (URL) throws -> ProjectStorageScanResult,
            beforeAppendDisposition:
                @escaping (ProjectStorageCleanupDispositionRecord) throws
                    -> Void,
            didOpenStateLog: @escaping (Int32) -> Void,
            syncFile: @escaping (Int32) -> Int32,
            renameExclusive:
                @escaping (Int32, String, Int32, String, UInt32) -> Int32,
            syncDirectory: @escaping (Int32) -> Int32,
            trashItem: @escaping (URL) throws -> URL,
            checkpoint: @escaping (Checkpoint, UUID) throws -> Void
        ) {
            self.init(
                cancellationCheck: cancellationCheck,
                acquireAssociatedLock: acquireAssociatedLock,
                authoritativeScan: authoritativeScan,
                beforeAppendDisposition: beforeAppendDisposition,
                didOpenStateLog: didOpenStateLog,
                renameExclusive: renameExclusive,
                syncFile: syncFile,
                syncDirectory: syncDirectory,
                trashItem: trashItem,
                checkpoint: checkpoint
            )
        }

        init(
            beforeAppendDisposition:
                @escaping (ProjectStorageCleanupDispositionRecord) throws
                    -> Void,
            authoritativeScan:
                @escaping (URL) throws -> ProjectStorageScanResult,
            checkpoint:
                @escaping (Checkpoint, UUID) throws -> Void = { _, _ in }
        ) {
            self.init(
                authoritativeScan: authoritativeScan,
                beforeAppendDisposition: beforeAppendDisposition,
                checkpoint: checkpoint
            )
        }

        init(
            cancellationCheck: @escaping () throws -> Void,
            beforeAppendDisposition:
                @escaping (ProjectStorageCleanupDispositionRecord) throws
                    -> Void,
            afterAuthorityVerified:
                @escaping (ProjectStorageCleanupJournal.Item) throws -> Void,
            trashItem: @escaping (URL) throws -> URL,
            checkpoint:
                @escaping (Checkpoint, UUID) throws -> Void = { _, _ in }
        ) {
            self.init(
                cancellationCheck: cancellationCheck,
                afterAuthorityVerified: afterAuthorityVerified,
                beforeAppendDisposition: beforeAppendDisposition,
                trashItem: trashItem,
                checkpoint: checkpoint
            )
        }

        init(
            cancellationCheck: @escaping () throws -> Void,
            beforeAppendDisposition:
                @escaping (ProjectStorageCleanupDispositionRecord) throws
                    -> Void,
            syncFile: @escaping (Int32) -> Int32,
            syncDirectory: @escaping (Int32) -> Int32,
            afterAuthorityVerified:
                @escaping (ProjectStorageCleanupJournal.Item) throws -> Void,
            trashItem: @escaping (URL) throws -> URL,
            checkpoint: @escaping (Checkpoint, UUID) throws -> Void
        ) {
            self.init(
                cancellationCheck: cancellationCheck,
                afterAuthorityVerified: afterAuthorityVerified,
                beforeAppendDisposition: beforeAppendDisposition,
                syncFile: syncFile,
                syncDirectory: syncDirectory,
                trashItem: trashItem,
                checkpoint: checkpoint
            )
        }

        init(
            beforeAppendDisposition:
                @escaping (ProjectStorageCleanupDispositionRecord) throws
                    -> Void,
            syncFile: @escaping (Int32) -> Int32,
            syncDirectory: @escaping (Int32) -> Int32,
            authoritativeScan:
                @escaping (URL) throws -> ProjectStorageScanResult,
            checkpoint:
                @escaping (Checkpoint, UUID) throws -> Void = { _, _ in }
        ) {
            self.init(
                authoritativeScan: authoritativeScan,
                beforeAppendDisposition: beforeAppendDisposition,
                syncFile: syncFile,
                syncDirectory: syncDirectory,
                checkpoint: checkpoint
            )
        }
    }

    private struct Authority {
        let project: URL
        let operation: URL
        let journalURL: URL
        let provenanceURL: URL
        let journalData: Data
        let provenanceData: Data
        let journal: ProjectStorageCleanupJournal
        let provenance: ProvenanceEnvelope
    }

    private let operations: Operations
    private let usesProductionAssociatedLocks: Bool

    public init() {
        operations = .init()
        usesProductionAssociatedLocks = true
    }

    init(operations: Operations) {
        self.operations = operations
        usesProductionAssociatedLocks = false
    }

    init(
        operations: Operations,
        usesProductionAssociatedLocks: Bool
    ) {
        self.operations = operations
        self.usesProductionAssociatedLocks = usesProductionAssociatedLocks
    }

    public func execute(
        _ request: ProjectStorageCleanupExecutionRequest
    ) async throws -> ProjectStorageCleanupExecutionResult {
        let authority = try loadAuthority(request)
        try await ProjectStorageCleanupIdentityGate.shared.acquire(
            authority.journal.projectIdentity
        )
        do {
            try Task.checkCancellation()
            let result = try await executeLocked(request, authority: authority)
            await ProjectStorageCleanupIdentityGate.shared.release(
                authority.journal.projectIdentity
            )
            return result
        } catch {
            await ProjectStorageCleanupIdentityGate.shared.release(
                authority.journal.projectIdentity
            )
            throw error
        }
    }

    private func executeLocked(
        _ request: ProjectStorageCleanupExecutionRequest,
        authority: Authority
    ) async throws -> ProjectStorageCleanupExecutionResult {
        let operationDescriptor = try openDirectory(authority.operation)
        defer { Darwin.close(operationDescriptor) }
        let projectCleanupLock: OwnedRunLock?
        if usesProductionAssociatedLocks {
            let lockURL = authority.project
                .appendingPathComponent(
                    ProjectOperationHistoryWriter.historyDirectoryName,
                    isDirectory: true
                )
                .appendingPathComponent(".project-storage-cleanup.lock")
            projectCleanupLock = try OwnedRunLock.acquire(at: lockURL)
        } else {
            projectCleanupLock = nil
        }
        defer { projectCleanupLock?.release() }
        var records = try loadState(
            operationDescriptor: operationDescriptor,
            authority: authority
        )
        if usesProductionAssociatedLocks {
            return try executeProductionLocked(
                request,
                authority: authority,
                operationDescriptor: operationDescriptor,
                records: &records
            )
        }

        let releaseAssociatedLock: () -> Void
        do {
            releaseAssociatedLock = try operations.acquireAssociatedLock(
                authority.project,
                authority.journal.projectIdentity,
                authority.journal.cleanupID
            )
        } catch {
            let reason = "Associated cleanup lock is held or unavailable: \(error)"
            for item in authority.journal.items
                where terminalRecord(for: item.id, in: records) == nil {
                records.append(
                    try append(
                        record(
                            for: item,
                            authority: authority,
                            state: .skipped,
                            reason: reason
                        ),
                        operationDescriptor: operationDescriptor,
                        operationURL: authority.operation
                    )
                )
            }
            return try publishResult(
                request,
                authority: authority,
                records: records,
                operationDescriptor: operationDescriptor,
                exitStatus: 0,
                stderr: ""
            )
        }
        defer { releaseAssociatedLock() }

        let authoritativeScan: () throws -> ProjectStorageScanResult = {
            try operations.authoritativeScan(authority.project)
        }
        let scan: ProjectStorageScanResult
        do {
            scan = try authoritativeScan()
        } catch is CancellationError {
            let reason = "Project storage cleanup cancelled during revalidation."
            for item in authority.journal.items
                where terminalRecord(for: item.id, in: records) == nil {
                records.append(
                    try append(
                        record(
                            for: item,
                            authority: authority,
                            state: .skipped,
                            reason: reason
                        ),
                        operationDescriptor: operationDescriptor,
                        operationURL: authority.operation
                    )
                )
            }
            _ = try publishResult(
                request,
                authority: authority,
                records: records,
                operationDescriptor: operationDescriptor,
                exitStatus: 130,
                stderr: reason
            )
            throw CancellationError()
        } catch {
            let reason = "Authoritative storage scan failed: \(error)"
            for item in authority.journal.items
                where terminalRecord(for: item.id, in: records) == nil {
                records.append(
                    try append(
                        record(
                            for: item,
                            authority: authority,
                            state: .failed,
                            reason: reason
                        ),
                        operationDescriptor: operationDescriptor,
                        operationURL: authority.operation
                    )
                )
            }
            _ = try publishResult(
                request,
                authority: authority,
                records: records,
                operationDescriptor: operationDescriptor,
                exitStatus: 1,
                stderr: reason
            )
            throw error
        }

        var cancellationError: Error?
        for (index, item) in authority.journal.items.enumerated() {
            if terminalRecord(for: item.id, in: records) != nil {
                continue
            }
            do {
                try operations.cancellationCheck()
            } catch {
                cancellationError = error
                let reason = "Cleanup cancelled before this item."
                for remaining in authority.journal.items[index...]
                    where terminalRecord(
                        for: remaining.id,
                        in: records
                    ) == nil {
                    records.append(
                        try append(
                            record(
                                for: remaining,
                                authority: authority,
                                state: .skipped,
                                reason: reason
                            ),
                            operationDescriptor: operationDescriptor,
                            operationURL: authority.operation
                        )
                    )
                }
                break
            }

            do {
                let newRecords = try process(
                    item,
                    authority: authority,
                    authoritativeScan: scan,
                    authoritativeRescan: authoritativeScan,
                    existingRecords: records,
                    operationDescriptor: operationDescriptor
                )
                records.append(contentsOf: newRecords)
            } catch is CancellationError {
                records = try loadState(
                    operationDescriptor: operationDescriptor,
                    authority: authority
                )
                let currentRecords = records.filter { $0.itemID == item.id }
                if currentRecords.isEmpty {
                    records.append(
                        try append(
                            record(
                                for: item,
                                authority: authority,
                                state: .skipped,
                                reason:
                                    "Cleanup cancelled before this item was detached."
                            ),
                            operationDescriptor: operationDescriptor,
                            operationURL: authority.operation
                        )
                    )
                } else if terminalRecord(for: item.id, in: records) == nil {
                    records.append(
                        contentsOf: try process(
                            item,
                            authority: authority,
                            authoritativeScan: scan,
                            authoritativeRescan: authoritativeScan,
                            existingRecords: records,
                            operationDescriptor: operationDescriptor
                        )
                    )
                }
                if index + 1 < authority.journal.items.count {
                    for remaining in authority.journal.items[(index + 1)...]
                    where terminalRecord(
                        for: remaining.id,
                        in: records
                    ) == nil {
                        records.append(
                            try append(
                                record(
                                    for: remaining,
                                    authority: authority,
                                    state: .skipped,
                                    reason:
                                        "Cleanup cancelled before this item."
                                ),
                                operationDescriptor: operationDescriptor,
                                operationURL: authority.operation
                            )
                        )
                    }
                }
                cancellationError = CancellationError()
                break
            }
            try operations.checkpoint(.afterItemTerminalBeforeNext, item.id)
        }

        if let cancellationError {
            _ = try publishResult(
                request,
                authority: authority,
                records: records,
                operationDescriptor: operationDescriptor,
                exitStatus: 130,
                stderr: "Project storage cleanup cancelled: \(cancellationError)"
            )
            throw cancellationError
        }
        let failureRecords = records.filter {
            switch $0.state {
            case .failed, .restoredAfterTrashFailure,
                 .quarantineRetained, .outcomeUnknown:
                return true
            default:
                return false
            }
        }
        return try publishResult(
            request,
            authority: authority,
            records: records,
            operationDescriptor: operationDescriptor,
            exitStatus: failureRecords.isEmpty ? 0 : 1,
            stderr: failureRecords.compactMap(\.reason).joined(
                separator: "\n"
            )
        )
    }

    private func executeProductionLocked(
        _ request: ProjectStorageCleanupExecutionRequest,
        authority: Authority,
        operationDescriptor: Int32,
        records: inout [ProjectStorageCleanupDispositionRecord]
    ) throws -> ProjectStorageCleanupExecutionResult {
        var cancellationError: Error?
        for (index, item) in authority.journal.items.enumerated() {
            if terminalRecord(for: item.id, in: records) != nil { continue }
            do {
                try operations.cancellationCheck()
            } catch {
                cancellationError = error
                try appendSkippedRemainder(
                    from: index,
                    reason: "Cleanup cancelled before this item.",
                    authority: authority,
                    operationDescriptor: operationDescriptor,
                    records: &records
                )
                break
            }

            let lease: ProductionLockLease
            do {
                lease = try acquireProductionAssociatedLocks(
                    authority,
                    items: [item]
                )
            } catch {
                records.append(
                    try append(
                        record(
                            for: item,
                            authority: authority,
                            state: .skipped,
                            reason:
                                "Associated cleanup lock is held or unavailable: \(errorDetail(error))"
                        ),
                        operationDescriptor: operationDescriptor,
                        operationURL: authority.operation
                    )
                )
                continue
            }
            let authoritativeScan: () throws -> ProjectStorageScanResult = {
                try ProjectStorageScanner(
                    callerHeldRunLocks: lease.runLocks,
                    callerHeldWorkbookPublicationLocks:
                        lease.workbookLocks
                ).scan(projectURL: authority.project)
            }
            do {
                let scan = try authoritativeScan()
                records.append(
                    contentsOf: try process(
                        item,
                        authority: authority,
                        authoritativeScan: scan,
                        authoritativeRescan: authoritativeScan,
                        existingRecords: records,
                        operationDescriptor: operationDescriptor
                    )
                )
                try operations.checkpoint(
                    .afterItemTerminalBeforeNext,
                    item.id
                )
                lease.release()
            } catch is CancellationError {
                records = try loadState(
                    operationDescriptor: operationDescriptor,
                    authority: authority
                )
                let current = records.filter { $0.itemID == item.id }
                if current.isEmpty {
                    records.append(
                        try append(
                            record(
                                for: item,
                                authority: authority,
                                state: .skipped,
                                reason:
                                    "Cleanup cancelled before this item was detached."
                            ),
                            operationDescriptor: operationDescriptor,
                            operationURL: authority.operation
                        )
                    )
                } else if terminalRecord(for: item.id, in: records) == nil {
                    do {
                        let scan = try authoritativeScan()
                        records.append(
                            contentsOf: try process(
                                item,
                                authority: authority,
                                authoritativeScan: scan,
                                authoritativeRescan: authoritativeScan,
                                existingRecords: records,
                                operationDescriptor: operationDescriptor
                            )
                        )
                    } catch {
                        records.append(
                            try append(
                                record(
                                    for: item,
                                    authority: authority,
                                    state: .outcomeUnknown,
                                    reason:
                                        "Cancellation interrupted recovery: \(errorDetail(error))"
                                ),
                                operationDescriptor: operationDescriptor,
                                operationURL: authority.operation
                            )
                        )
                    }
                }
                lease.release()
                try appendSkippedRemainder(
                    from: index + 1,
                    reason: "Cleanup cancelled before this item.",
                    authority: authority,
                    operationDescriptor: operationDescriptor,
                    records: &records
                )
                cancellationError = CancellationError()
                break
            } catch {
                records = try loadState(
                    operationDescriptor: operationDescriptor,
                    authority: authority
                )
                if terminalRecord(for: item.id, in: records) == nil {
                    let prior = records.last { $0.itemID == item.id }
                    records.append(
                        try append(
                            record(
                                for: item,
                                authority: authority,
                                state: prior == nil ? .failed : .outcomeUnknown,
                                quarantineRelativePath: prior == nil
                                    ? nil
                                    : prior?.quarantineRelativePath
                                        ?? deterministicQuarantineRelativePath(
                                            for: item,
                                            authority: authority
                                        ),
                                quarantineIdentity: prior == nil
                                    ? nil
                                    : prior?.quarantineIdentity
                                        ?? item.sourceIdentity,
                                reason:
                                    "Cleanup execution failed: \(errorDetail(error))"
                            ),
                            operationDescriptor: operationDescriptor,
                            operationURL: authority.operation
                        )
                    )
                }
                lease.release()
            }
        }

        if let cancellationError {
            let stderr =
                "Project storage cleanup cancelled: \(errorDetail(cancellationError))"
            _ = try publishResult(
                request,
                authority: authority,
                records: records,
                operationDescriptor: operationDescriptor,
                exitStatus: 130,
                stderr: stderr
            )
            throw cancellationError
        }
        let failures = executionFailureRecords(records)
        return try publishResult(
            request,
            authority: authority,
            records: records,
            operationDescriptor: operationDescriptor,
            exitStatus: failures.isEmpty ? 0 : 1,
            stderr: failures.compactMap(\.reason).joined(separator: "\n")
        )
    }

    private func appendSkippedRemainder(
        from index: Int,
        reason: String,
        authority: Authority,
        operationDescriptor: Int32,
        records: inout [ProjectStorageCleanupDispositionRecord]
    ) throws {
        guard index < authority.journal.items.count else { return }
        for item in authority.journal.items[index...]
        where terminalRecord(for: item.id, in: records) == nil {
            let disposition = try append(
                record(
                    for: item,
                    authority: authority,
                    state: .skipped,
                    reason: reason
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
            records.append(disposition)
        }
    }

    private func executionFailureRecords(
        _ records: [ProjectStorageCleanupDispositionRecord]
    ) -> [ProjectStorageCleanupDispositionRecord] {
        records.filter {
            switch $0.state {
            case .failed, .restoredAfterTrashFailure,
                 .quarantineRetained, .outcomeUnknown:
                return true
            default:
                return false
            }
        }
    }

    private func process(
        _ item: ProjectStorageCleanupJournal.Item,
        authority: Authority,
        authoritativeScan: ProjectStorageScanResult,
        authoritativeRescan: () throws -> ProjectStorageScanResult,
        existingRecords: [ProjectStorageCleanupDispositionRecord],
        operationDescriptor: Int32
    ) throws -> [ProjectStorageCleanupDispositionRecord] {
        var appended: [ProjectStorageCleanupDispositionRecord] = []
        let prior = existingRecords.filter { $0.itemID == item.id }

        if let recovered = try recoverIfNeeded(
            item,
            authority: authority,
            prior: prior,
            operationDescriptor: operationDescriptor
        ) {
            appended.append(recovered)
            if recovered.state.isTerminal { return appended }
        }

        let latest = (prior + appended).last
        if latest == nil {
            guard exactSelection(
                item,
                in: authoritativeScan,
                projectIdentity: authority.journal.projectIdentity
            ), try verifyInventory(
                item,
                project: authority.project,
                scan: authoritativeScan
            ) else {
                let skipped = try append(
                    record(
                        for: item,
                        authority: authority,
                        state: .skipped,
                        reason:
                            "Source classification, identity, or inventory changed."
                    ),
                    operationDescriptor: operationDescriptor,
                    operationURL: authority.operation
                )
                return [skipped]
            }
            try operations.afterAuthorityVerified(item)
            let finalScan = try authoritativeRescan()
            guard exactSelection(
                item,
                in: finalScan,
                projectIdentity: authority.journal.projectIdentity
            ), try verifyInventory(
                item,
                project: authority.project,
                scan: finalScan
            ) else {
                let skipped = try append(
                    record(
                        for: item,
                        authority: authority,
                        state: .skipped,
                        reason:
                            "Source changed or is now covered by a keep policy at the final pre-detach gate."
                    ),
                    operationDescriptor: operationDescriptor,
                    operationURL: authority.operation
                )
                return [skipped]
            }
            let intent = try append(
                record(
                    for: item,
                    authority: authority,
                    state: .detachIntent
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
            appended.append(intent)
            try operations.checkpoint(.afterDetachIntentBeforeRename, item.id)
        }

        let quarantineName = quarantineLeaf(
            cleanupID: authority.journal.cleanupID,
            itemID: item.id
        )
        let sourceURL = authority.project.appendingPathComponent(
            item.sourceRelativePath
        )
        let sourceParentURL = sourceURL.deletingLastPathComponent()
        let sourceLeaf = sourceURL.lastPathComponent
        let quarantineURL = sourceParentURL.appendingPathComponent(
            quarantineName
        )

        var latestState = (prior + appended).last?.state
        var quarantineIdentity = (prior + appended).last?
            .quarantineIdentity
        if latestState == .detachIntent {
            let parentDescriptor = try openDirectory(sourceParentURL)
            defer { Darwin.close(parentDescriptor) }
            guard let sourceObject = try objectIfPresent(
                sourceLeaf,
                in: parentDescriptor
            ),
                sourceObject.identity == item.sourceIdentity,
                sourceObject.isDirectory else {
                let skipped = try append(
                    record(
                        for: item,
                        authority: authority,
                        state: .skipped,
                        reason:
                            "Source identity or type changed immediately before detach."
                    ),
                    operationDescriptor: operationDescriptor,
                    operationURL: authority.operation
                )
                appended.append(skipped)
                return appended
            }
            let renameStatus = operations.renameExclusive(
                parentDescriptor,
                sourceLeaf,
                parentDescriptor,
                quarantineName,
                UInt32(RENAME_EXCL)
            )
            guard renameStatus == 0 else {
                let reason = "Exclusive detach failed (errno \(errno))."
                let skipped = try append(
                    record(
                        for: item,
                        authority: authority,
                        state: .skipped,
                        reason: reason
                    ),
                    operationDescriptor: operationDescriptor,
                    operationURL: authority.operation
                )
                appended.append(skipped)
                return appended
            }
            try operations.checkpoint(.afterDetachBeforeParentSync, item.id)
            try operations.checkpoint(.afterDetachBeforeRecord, item.id)
            guard operations.syncDirectory(parentDescriptor) == 0 else {
                throw systemFailure(
                    quarantineURL,
                    "fsync detached source parent"
                )
            }
            try operations.checkpoint(
                .afterDetachParentSyncBeforeRecord,
                item.id
            )
            guard let detachedObject = try objectIfPresent(
                quarantineName,
                in: parentDescriptor
            ),
                detachedObject.identity == item.sourceIdentity,
                detachedObject.isDirectory else {
                let unknown = try append(
                    record(
                        for: item,
                        authority: authority,
                        state: .outcomeUnknown,
                        quarantineRelativePath:
                            relativePath(
                                quarantineURL,
                                under: authority.project
                            ),
                        quarantineIdentity: item.sourceIdentity,
                        reason:
                            "Detached quarantine identity or type changed before it could be recorded."
                    ),
                    operationDescriptor: operationDescriptor,
                    operationURL: authority.operation
                )
                appended.append(unknown)
                return appended
            }
            quarantineIdentity = detachedObject.identity
            let detached = try append(
                record(
                    for: item,
                    authority: authority,
                    state: .detached,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: quarantineIdentity
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
            appended.append(detached)
            latestState = .detached
            try operations.checkpoint(
                .afterDetachedRecordBeforeTrashIntent,
                item.id
            )
        }

        if latestState == .detached {
            let trashIntent = try append(
                record(
                    for: item,
                    authority: authority,
                    state: .trashIntent,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: quarantineIdentity
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
            appended.append(trashIntent)
            latestState = .trashIntent
        }

        guard latestState == .trashIntent else { return appended }
        try operations.checkpoint(.afterTrashIntentBeforeTrash, item.id)
        let trashParent = try openDirectory(sourceParentURL)
        defer { Darwin.close(trashParent) }
        guard let trashObject = try objectIfPresent(
            quarantineName,
            in: trashParent
        ),
            trashObject.identity == quarantineIdentity,
            trashObject.isDirectory else {
            let unknown = try append(
                record(
                    for: item,
                    authority: authority,
                    state: .outcomeUnknown,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: quarantineIdentity,
                    reason:
                        "Quarantine identity or type changed immediately before Trash."
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
            appended.append(unknown)
            return appended
        }
        let destination: URL
        do {
            destination = try operations.trashItem(quarantineURL)
        } catch {
            let trashFailureReason =
                "Recoverable Trash rejected the quarantined item: "
                + errorDetail(error)
            let failure = try append(
                record(
                    for: item,
                    authority: authority,
                    state: .trashFailed,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: quarantineIdentity,
                    reason: trashFailureReason
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
            appended.append(failure)
            try operations.checkpoint(.afterTrashFailureBeforeRestore, item.id)
            appended.append(
                try restoreAfterTrashFailure(
                    item,
                    authority: authority,
                    operationDescriptor: operationDescriptor,
                    sourceParentURL: sourceParentURL,
                    sourceURL: sourceURL,
                    sourceLeaf: sourceLeaf,
                    quarantineURL: quarantineURL,
                    quarantineName: quarantineName,
                    quarantineIdentity: quarantineIdentity,
                    trashFailureReason: trashFailureReason
                )
            )
            return appended
        }
        // A crash after the recoverable Trash operation has succeeded is not a
        // Trash failure. Let it escape so restart observes the missing
        // quarantine and records outcome-unknown without attempting Trash twice.
        try operations.checkpoint(.afterTrashBeforeRecord, item.id)
        let moved = try append(
            record(
                for: item,
                authority: authority,
                state: .movedToTrash,
                quarantineRelativePath:
                    relativePath(quarantineURL, under: authority.project),
                quarantineIdentity: quarantineIdentity,
                trashDestinationPath: destination.path
            ),
            operationDescriptor: operationDescriptor,
            operationURL: authority.operation
        )
        appended.append(moved)
        return appended
    }

    private func restoreAfterTrashFailure(
        _ item: ProjectStorageCleanupJournal.Item,
        authority: Authority,
        operationDescriptor: Int32,
        sourceParentURL: URL,
        sourceURL: URL,
        sourceLeaf: String,
        quarantineURL: URL,
        quarantineName: String,
        quarantineIdentity: FileSystemObjectIdentity?,
        trashFailureReason: String
    ) throws -> ProjectStorageCleanupDispositionRecord {
        let parentDescriptor = try openDirectory(sourceParentURL)
        defer { Darwin.close(parentDescriptor) }
        guard try identityIfPresent(
            quarantineName,
            in: parentDescriptor
        ) == quarantineIdentity else {
            return try append(
                record(
                    for: item,
                    authority: authority,
                    state: .outcomeUnknown,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: quarantineIdentity,
                    reason:
                        "Trash outcome is unknown because quarantine identity changed."
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
        }
        let restoreStatus = operations.renameExclusive(
            parentDescriptor,
            quarantineName,
            parentDescriptor,
            sourceLeaf,
            UInt32(RENAME_EXCL)
        )
        let restoreError = errno
        if restoreStatus == 0 {
            try operations.checkpoint(.afterRestoreBeforeParentSync, item.id)
            try operations.checkpoint(.afterRestoreBeforeRecord, item.id)
            guard operations.syncDirectory(parentDescriptor) == 0 else {
                throw systemFailure(sourceURL, "fsync restored source parent")
            }
            try operations.checkpoint(
                .afterRestoreParentSyncBeforeRecord,
                item.id
            )
            return try append(
                record(
                    for: item,
                    authority: authority,
                    state: .restoredAfterTrashFailure,
                    reason:
                        "\(trashFailureReason) The original item was restored."
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
        }
        try operations.checkpoint(.afterQuarantineRetainedBeforeRecord, item.id)
        let retentionDetail: String
        if restoreError == EEXIST || restoreError == ENOTEMPTY {
            retentionDetail = "The original name is occupied."
        } else {
            retentionDetail =
                "Restore failed with errno \(restoreError) and the quarantine was retained."
        }
        return try append(
            record(
                for: item,
                authority: authority,
                state: .quarantineRetained,
                quarantineRelativePath:
                    relativePath(quarantineURL, under: authority.project),
                quarantineIdentity: quarantineIdentity,
                reason:
                    "\(trashFailureReason) \(retentionDetail)"
            ),
            operationDescriptor: operationDescriptor,
            operationURL: authority.operation
        )
    }

    private func recoverIfNeeded(
        _ item: ProjectStorageCleanupJournal.Item,
        authority: Authority,
        prior: [ProjectStorageCleanupDispositionRecord],
        operationDescriptor: Int32
    ) throws -> ProjectStorageCleanupDispositionRecord? {
        guard let last = prior.last, !last.state.isTerminal else { return nil }
        let sourceURL = authority.project.appendingPathComponent(
            item.sourceRelativePath
        )
        let parentURL = sourceURL.deletingLastPathComponent()
        let parent = try openDirectory(parentURL)
        defer { Darwin.close(parent) }
        let sourceIdentity = try identityIfPresent(
            sourceURL.lastPathComponent,
            in: parent
        )
        let quarantineName = quarantineLeaf(
            cleanupID: authority.journal.cleanupID,
            itemID: item.id
        )
        let quarantineIdentity = try identityIfPresent(
            quarantineName,
            in: parent
        )
        let quarantineURL = parentURL.appendingPathComponent(quarantineName)

        if last.state == .trashFailed,
           sourceIdentity == nil,
           quarantineIdentity == last.quarantineIdentity {
            return try restoreAfterTrashFailure(
                item,
                authority: authority,
                operationDescriptor: operationDescriptor,
                sourceParentURL: parentURL,
                sourceURL: sourceURL,
                sourceLeaf: sourceURL.lastPathComponent,
                quarantineURL: quarantineURL,
                quarantineName: quarantineName,
                quarantineIdentity: quarantineIdentity,
                trashFailureReason:
                    last.reason
                    ?? "Recoverable Trash failed for an unknown reason."
            )
        }

        if sourceIdentity == item.sourceIdentity, quarantineIdentity == nil {
            if last.state == .trashIntent || last.state == .trashFailed {
                guard operations.syncDirectory(parent) == 0 else {
                    throw systemFailure(
                        sourceURL,
                        "fsync recovered restored source parent"
                    )
                }
                return try append(
                    record(
                        for: item,
                        authority: authority,
                        state: .restoredAfterTrashFailure,
                        reason:
                            "Recovered a completed restore after interruption."
                    ),
                    operationDescriptor: operationDescriptor,
                    operationURL: authority.operation
                )
            }
            return nil
        }
        if sourceIdentity == nil,
           quarantineIdentity == item.sourceIdentity,
           last.state == .detachIntent {
            return try append(
                record(
                    for: item,
                    authority: authority,
                    state: .detached,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: quarantineIdentity
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
        }
        if sourceIdentity == nil,
           let expected = last.quarantineIdentity,
           quarantineIdentity == expected {
            return nil
        }
        if sourceIdentity != nil,
           let expected = last.quarantineIdentity,
           quarantineIdentity == expected {
            return try append(
                record(
                    for: item,
                    authority: authority,
                    state: .quarantineRetained,
                    quarantineRelativePath:
                        relativePath(quarantineURL, under: authority.project),
                    quarantineIdentity: expected,
                    reason:
                        "Recovered retained quarantine after interruption."
                ),
                operationDescriptor: operationDescriptor,
                operationURL: authority.operation
            )
        }
        return try append(
            record(
                for: item,
                authority: authority,
                state: .outcomeUnknown,
                quarantineRelativePath:
                    relativePath(quarantineURL, under: authority.project),
                quarantineIdentity: last.quarantineIdentity,
                reason:
                    "Quarantine identity is unknown; the prior Trash outcome cannot be proven."
            ),
            operationDescriptor: operationDescriptor,
            operationURL: authority.operation
        )
    }

    private func loadAuthority(
        _ request: ProjectStorageCleanupExecutionRequest
    ) throws -> Authority {
        let project = request.projectURL.standardizedFileURL
        let actualProjectIdentity = try FileSystemObjectIdentity.noFollow(
            project
        )
        let operation = project
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                ProjectStorageCleanupReceiptWriter.collectionDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                request.cleanupID.uuidString.lowercased(),
                isDirectory: true
            )
        let descriptor = try openDirectory(operation)
        defer { Darwin.close(descriptor) }
        let journalData = try readStableRegularFile(
            ProjectStorageCleanupReceiptWriter.journalFileName,
            role: .journal,
            directoryDescriptor: descriptor,
            directoryURL: operation
        )
        let provenanceData = try readStableRegularFile(
            ProjectStorageCleanupReceiptWriter.provenanceFileName,
            role: .provenance,
            directoryDescriptor: descriptor,
            directoryURL: operation
        )
        let journal = try ProvenanceJSON.decoder.decode(
            ProjectStorageCleanupJournal.self,
            from: journalData
        )
        let provenance = try ProvenanceEnvelopeReader.decodeCanonical(
            provenanceData
        )
        let journalURL = operation.appendingPathComponent(
            ProjectStorageCleanupReceiptWriter.journalFileName
        )
        let provenanceURL = operation.appendingPathComponent(
            ProjectStorageCleanupReceiptWriter.provenanceFileName
        )
        guard journal.cleanupID == request.cleanupID,
              journal.projectIdentity == actualProjectIdentity,
              journal.projectRoot == project.path,
              journal.provenanceFileName
                == ProjectStorageCleanupReceiptWriter.provenanceFileName,
              provenance.id == request.cleanupID,
              provenance.output?.path == journalURL.path,
              provenance.output?.checksumSHA256 == sha256(journalData),
              provenance.output?.fileSize == UInt64(journalData.count),
              journal.intendedAction == .moveToTrash,
              journal.items.allSatisfy({
                  $0.intendedAction == .moveToTrash
                      && $0.classification.isRemovable
              }) else {
            throw ProjectStorageCleanupExecutionError.unsafeAuthority(
                operation.path
            )
        }
        return Authority(
            project: project,
            operation: operation,
            journalURL: journalURL,
            provenanceURL: provenanceURL,
            journalData: journalData,
            provenanceData: provenanceData,
            journal: journal,
            provenance: provenance
        )
    }

    private func readStableRegularFile(
        _ name: String,
        role: PreparationFileRole,
        directoryDescriptor: Int32,
        directoryURL: URL
    ) throws -> Data {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw systemFailure(
                directoryURL.appendingPathComponent(name),
                "open cleanup preparation file"
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= 32 * 1_024 * 1_024 else {
            throw ProjectStorageCleanupExecutionError.unsafeAuthority(
                directoryURL.appendingPathComponent(name).path
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemFailure(
                    directoryURL.appendingPathComponent(name),
                    "read cleanup preparation file"
                )
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        try operations.afterReadPreparationFile(role)
        var afterDescriptor = stat()
        var afterPath = stat()
        let pathStatus = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &afterPath,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &afterDescriptor) == 0,
              pathStatus == 0,
              FileSystemObjectIdentity(from: before)
                == FileSystemObjectIdentity(from: afterDescriptor),
              FileSystemObjectIdentity(from: before)
                == FileSystemObjectIdentity(from: afterPath),
              afterPath.st_mode & S_IFMT == S_IFREG,
              before.st_size == afterDescriptor.st_size,
              before.st_mtimespec.tv_sec == afterDescriptor.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec
                == afterDescriptor.st_mtimespec.tv_nsec,
              data.count == before.st_size else {
            throw ProjectStorageCleanupExecutionError.unsafeAuthority(
                directoryURL.appendingPathComponent(name).path
            )
        }
        return data
    }

    private func loadState(
        operationDescriptor: Int32,
        authority: Authority
    ) throws -> [ProjectStorageCleanupDispositionRecord] {
        let descriptor = Self.stateFileName.withCString {
            Darwin.openat(
                operationDescriptor,
                $0,
                O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw systemFailure(
                authority.operation.appendingPathComponent(Self.stateFileName),
                "open cleanup state"
            )
        }
        defer { Darwin.close(descriptor) }
        operations.didOpenStateLog(descriptor)
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw ProjectStorageCleanupExecutionError.stateCorrupt(
                "state log is not a regular file"
            )
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw systemFailure(
                authority.operation.appendingPathComponent(Self.stateFileName),
                "seek cleanup state"
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemFailure(
                    authority.operation.appendingPathComponent(
                        Self.stateFileName
                    ),
                    "read cleanup state"
                )
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        if data.isEmpty { return [] }
        guard data.last == 0x0a else {
            throw ProjectStorageCleanupExecutionError.stateCorrupt(
                "state log has a torn final record"
            )
        }
        let records: [ProjectStorageCleanupDispositionRecord]
        do {
            records = try data.split(separator: 0x0a).map {
                try stateDecoder().decode(
                    ProjectStorageCleanupDispositionRecord.self,
                    from: Data($0)
                )
            }
        } catch {
            throw ProjectStorageCleanupExecutionError.stateCorrupt(
                "state log cannot be decoded"
            )
        }
        try validate(records, authority: authority)
        return records
    }

    private func validate(
        _ records: [ProjectStorageCleanupDispositionRecord],
        authority: Authority
    ) throws {
        let items = Dictionary(
            uniqueKeysWithValues: authority.journal.items.map { ($0.id, $0) }
        )
        var previous: [UUID: ProjectStorageCleanupDispositionRecord.State] =
            [:]
        for record in records {
            guard record.hasValidIntegrity,
                  record.cleanupID == authority.journal.cleanupID,
                  record.projectIdentity == authority.journal.projectIdentity,
                  let item = items[record.itemID],
                  record.sourceRelativePath == item.sourceRelativePath,
                  record.sourceIdentity == item.sourceIdentity,
                  validTransition(
                      from: previous[record.itemID],
                      to: record.state
                  ) else {
                throw ProjectStorageCleanupExecutionError.stateCorrupt(
                    "state record is not bound to its immutable authority"
                )
            }
            if [.detached, .trashIntent, .trashFailed, .movedToTrash,
                .quarantineRetained].contains(record.state) {
                guard record.quarantineRelativePath
                    == relativePath(
                        authority.project
                            .appendingPathComponent(
                                item.sourceRelativePath
                            )
                            .deletingLastPathComponent()
                            .appendingPathComponent(
                                quarantineLeaf(
                                    cleanupID:
                                        authority.journal.cleanupID,
                                    itemID: item.id
                                )
                            ),
                        under: authority.project
                    ),
                    record.quarantineIdentity != nil else {
                    throw ProjectStorageCleanupExecutionError.stateCorrupt(
                        "state record has invalid quarantine binding"
                    )
                }
            }
            previous[record.itemID] = record.state
        }
    }

    private func validTransition(
        from: ProjectStorageCleanupDispositionRecord.State?,
        to: ProjectStorageCleanupDispositionRecord.State
    ) -> Bool {
        guard let from else {
            return to == .detachIntent || to == .skipped || to == .failed
        }
        if from.isTerminal { return false }
        switch (from, to) {
        case (.detachIntent, .detached),
             (.detachIntent, .skipped),
             (.detachIntent, .outcomeUnknown),
             (.detached, .trashIntent),
             (.detached, .outcomeUnknown),
             (.trashIntent, .movedToTrash),
             (.trashIntent, .trashFailed),
             (.trashIntent, .outcomeUnknown):
            return true
        case (.trashFailed, .restoredAfterTrashFailure),
             (.trashFailed, .quarantineRetained),
             (.trashFailed, .outcomeUnknown):
            return true
        default:
            return false
        }
    }

    private func append(
        _ record: ProjectStorageCleanupDispositionRecord,
        operationDescriptor: Int32,
        operationURL: URL
    ) throws -> ProjectStorageCleanupDispositionRecord {
        try operations.beforeAppendDisposition(record)
        let descriptor = Self.stateFileName.withCString {
            Darwin.openat(
                operationDescriptor,
                $0,
                O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw systemFailure(
                operationURL.appendingPathComponent(Self.stateFileName),
                "open append-only cleanup state"
            )
        }
        defer { Darwin.close(descriptor) }
        operations.didOpenStateLog(descriptor)
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw ProjectStorageCleanupExecutionError.stateCorrupt(
                "state log is not regular"
            )
        }
        var data = try stateEncoder().encode(record)
        data.append(0x0a)
        try writeAll(
            data,
            descriptor: descriptor,
            path: operationURL.appendingPathComponent(Self.stateFileName)
        )
        try operations.checkpoint(
            .afterDispositionWriteBeforeFileSync,
            record.itemID
        )
        guard operations.syncFile(descriptor) == 0 else {
            throw systemFailure(
                operationURL.appendingPathComponent(Self.stateFileName),
                "fsync cleanup state"
            )
        }
        try operations.checkpoint(
            .afterDispositionFileSyncBeforeDirectorySync,
            record.itemID
        )
        guard operations.syncDirectory(operationDescriptor) == 0 else {
            throw systemFailure(operationURL, "fsync cleanup state parent")
        }
        try operations.checkpoint(.afterDispositionDurable, record.itemID)
        return record
    }

    private func publishResult(
        _ request: ProjectStorageCleanupExecutionRequest,
        authority: Authority,
        records: [ProjectStorageCleanupDispositionRecord],
        operationDescriptor: Int32,
        exitStatus: Int,
        stderr: String
    ) throws -> ProjectStorageCleanupExecutionResult {
        let completedAt = operations.now()
        let summaryItems = authority.journal.items.compactMap { item -> ProjectStorageCleanupExecutionSummary.Item? in
            guard let terminal = terminalRecord(for: item.id, in: records) else {
                return nil
            }
            return .init(
                itemID: item.id,
                sourceRelativePath: item.sourceRelativePath,
                state: terminal.state,
                quarantineRelativePath: terminal.quarantineRelativePath,
                trashDestinationPath: terminal.trashDestinationPath,
                reason: terminal.reason
            )
        }
        let summaryState: ProjectStorageCleanupExecutionSummary.State
        if exitStatus != 0, summaryItems.allSatisfy({ $0.state == .failed }) {
            summaryState = .failed
        } else if exitStatus != 0
                    || summaryItems.contains(where: {
                        $0.state != .movedToTrash
                    }) {
            summaryState = .completedWithFailures
        } else {
            summaryState = .completed
        }
        let summary = ProjectStorageCleanupExecutionSummary(
            cleanupID: authority.journal.cleanupID,
            projectRoot: authority.project.path,
            projectIdentity: authority.journal.projectIdentity,
            state: summaryState,
            items: summaryItems,
            startedAt: request.startedAt,
            completedAt: completedAt,
            exitStatus: exitStatus,
            wallTimeSeconds: max(
                0,
                completedAt.timeIntervalSince(request.startedAt)
            ),
            stderr: stderr
        )
        let sequence = nextPublicationSequence(operationURL: authority.operation)
        let summaryName = String(
            format: "execution-summary-%08d.json",
            sequence
        )
        let summaryData = try ProvenanceJSON.encoder.encode(summary)
        let summaryURL = try publish(
            summaryData,
            named: summaryName,
            operationDescriptor: operationDescriptor,
            operationURL: authority.operation,
            writeCheckpoint: .afterSummaryWriteBeforeFileSync,
            fileSyncCheckpoint: .afterSummaryFileSyncBeforeDirectorySync,
            directorySyncCheckpoint:
                .afterSummaryDirectorySyncBeforeDurable,
            durableCheckpoint: .afterSummaryDurable,
            cleanupID: authority.journal.cleanupID
        )

        let stateURL = authority.operation.appendingPathComponent(
            Self.stateFileName
        )
        let stateData = try Data(contentsOf: stateURL)
        let inputs = [
            fileDescriptor(
                authority.journalURL,
                data: authority.journalData,
                role: .input
            ),
            fileDescriptor(
                authority.provenanceURL,
                data: authority.provenanceData,
                role: .input
            ),
        ]
        let outputs = [
            fileDescriptor(stateURL, data: stateData, role: .output),
            fileDescriptor(summaryURL, data: summaryData, role: .output),
        ]
        var resolved = request.options.resolvedDefaults
        resolved["cleanupID"] = .string(
            authority.journal.cleanupID.uuidString.lowercased()
        )
        resolved["projectRoot"] = .string(authority.project.path)
        resolved["executionStateDurability"] =
            .string("append-only-jsonl-fsync-file-and-directory")
        resolved["cleanupDispositions"] = .array(
            summaryItems.compactMap { summaryItem in
                guard let journalItem = authority.journal.items.first(
                    where: { $0.id == summaryItem.itemID }
                ) else { return nil }
                var value: [String: ParameterValue] = [
                    "itemID": .string(
                        summaryItem.itemID.uuidString.lowercased()
                    ),
                    "sourceRelativePath":
                        .string(journalItem.sourceRelativePath),
                    "sourceDevice":
                        .integer(Int(journalItem.sourceIdentity.device)),
                    "sourceInode":
                        .integer(Int(journalItem.sourceIdentity.inode)),
                    "aggregateTreeDigest":
                        .string(journalItem.aggregateTreeDigest),
                    "inventory": .array(
                        (try? journalItem.inventory.map {
                            try $0.parameterValue()
                        }) ?? []
                    ),
                    "state": .string(summaryItem.state.rawValue),
                ]
                if let reason = summaryItem.reason {
                    value["reason"] = .string(reason)
                }
                if let quarantine = summaryItem.quarantineRelativePath {
                    value["quarantineRelativePath"] = .string(quarantine)
                }
                if let destination = summaryItem.trashDestinationPath {
                    value["trashDestinationPath"] = .string(destination)
                }
                return .dictionary(value)
            }
        )
        let options = ProvenanceOptions(
            explicit: request.options.explicit,
            defaults: request.options.defaults,
            resolvedDefaults: resolved
        )
        let step = ProvenanceStep(
            toolName: authority.journal.toolName,
            toolVersion: authority.journal.toolVersion,
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv,
            resolvedOptions: resolved,
            runtimeIdentity: request.runtimeIdentity,
            inputs: inputs,
            outputs: outputs,
            exitStatus: exitStatus,
            wallTimeSeconds: summary.wallTimeSeconds,
            stderr: stderr,
            startedAt: request.startedAt,
            completedAt: completedAt
        )
        let provenance = ProvenanceEnvelope(
            id: authority.journal.cleanupID,
            createdAt: completedAt,
            workflowName: "Project Storage Cleanup Execution",
            workflowVersion: authority.journal.workflowVersion,
            toolName: authority.journal.toolName,
            toolVersion: authority.journal.toolVersion,
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv,
            options: options,
            runtimeIdentity: request.runtimeIdentity,
            files: inputs,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: summary.wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr
        )
        let provenanceData = try ProvenanceJSON.encoder.encode(provenance)
        let provenanceURL = try publish(
            provenanceData,
            named: String(
                format: "execution-provenance-%08d.json",
                sequence
            ),
            operationDescriptor: operationDescriptor,
            operationURL: authority.operation,
            writeCheckpoint: .afterProvenanceWriteBeforeFileSync,
            fileSyncCheckpoint:
                .afterProvenanceFileSyncBeforeDirectorySync,
            directorySyncCheckpoint:
                .afterProvenanceDirectorySyncBeforeDurable,
            durableCheckpoint: .afterProvenanceDurable,
            cleanupID: authority.journal.cleanupID
        )
        return ProjectStorageCleanupExecutionResult(
            summary: summary,
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
    }

    private func publish(
        _ data: Data,
        named name: String,
        operationDescriptor: Int32,
        operationURL: URL,
        writeCheckpoint: Checkpoint,
        fileSyncCheckpoint: Checkpoint,
        directorySyncCheckpoint: Checkpoint,
        durableCheckpoint: Checkpoint,
        cleanupID: UUID
    ) throws -> URL {
        let descriptor = name.withCString {
            Darwin.openat(
                operationDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw systemFailure(
                operationURL.appendingPathComponent(name),
                "create execution artifact"
            )
        }
        defer { Darwin.close(descriptor) }
        try writeAll(
            data,
            descriptor: descriptor,
            path: operationURL.appendingPathComponent(name)
        )
        try operations.checkpoint(writeCheckpoint, cleanupID)
        guard operations.syncFile(descriptor) == 0 else {
            throw systemFailure(
                operationURL.appendingPathComponent(name),
                "fsync execution artifact"
            )
        }
        try operations.checkpoint(fileSyncCheckpoint, cleanupID)
        guard operations.syncDirectory(operationDescriptor) == 0 else {
            throw systemFailure(operationURL, "fsync execution artifact parent")
        }
        try operations.checkpoint(directorySyncCheckpoint, cleanupID)
        try operations.checkpoint(durableCheckpoint, cleanupID)
        return operationURL.appendingPathComponent(name)
    }

    private func exactSelection(
        _ item: ProjectStorageCleanupJournal.Item,
        in scan: ProjectStorageScanResult,
        projectIdentity: FileSystemObjectIdentity
    ) -> Bool {
        guard scan.projectIdentity == projectIdentity,
              let entry = scan.entries.first(
                  where: { $0.relativePath == item.sourceRelativePath }
              ) else { return false }
        return entry.identity == item.sourceIdentity
            && entry.category == item.sourceCategory
            && entry.classification == item.classification
            && entry.classification.isRemovable
    }

    private func verifyInventory(
        _ item: ProjectStorageCleanupJournal.Item,
        project: URL,
        scan: ProjectStorageScanResult
    ) throws -> Bool {
        // Task 6's descriptor inventory verifier is kept as a separate
        // implementation unit so execution and preview share one exact
        // no-follow representation.
        try ProjectStorageCleanupInventoryVerifier.verify(
            item: item,
            projectURL: project,
            scan: scan
        )
    }

    private enum ProductionLockTarget {
        case run(URL)
        case workbook(bundle: URL, lock: URL)

        var lockURL: URL {
            switch self {
            case .run(let url): return url
            case .workbook(_, let lock): return lock
            }
        }
    }

    private struct ProductionLockLease {
        let runLocks: [OwnedRunLock]
        let workbookLocks: [ONTGenotypeBundlePublicationLock]

        func release() {
            workbookLocks.reversed().forEach { $0.release() }
            runLocks.reversed().forEach { $0.release() }
        }
    }

    /// Acquires every workflow lock named by an authoritative owned-work
    /// marker and every publication lock in a selected legacy workbook
    /// archive's analysis directory. Workbook acquisition is intentionally
    /// conservative: cleanup is rare, and holding all live bundle publication
    /// locks in the directory closes the legacy archive scan-to-detach race
    /// even when multiple live bundles share retired workbook descriptors.
    private func acquireProductionAssociatedLocks(
        _ authority: Authority,
        items: [ProjectStorageCleanupJournal.Item]
    ) throws -> ProductionLockLease {
        var targetsByPath: [String: ProductionLockTarget] = [:]
        var workbookParents: Set<URL> = []

        for item in items {
            let source = authority.project.appendingPathComponent(
                item.sourceRelativePath
            )
            switch item.sourceCategory {
            case .workflowStaging:
                let marker = try OwnedWorkDirectoryMarkerStore.load(
                    from: source,
                    expectedProjectURL: authority.project
                )
                guard let relative = marker.lockRelativePath else {
                    throw OwnedRunLockError.unsafeLockFile(
                        "No run lock is recorded for \(item.sourceRelativePath)"
                    )
                }
                let lock = authority.project.appendingPathComponent(relative)
                targetsByPath[lock.standardizedFileURL.path] = .run(lock)
            case .temporary:
                _ = try OwnedWorkDirectoryMarkerStore.load(
                    from: source,
                    expectedProjectURL: authority.project
                )
                // ProjectTempDirectory terminal children have no run lock.
                // The project-wide cleanup lock held by executeLocked is their
                // cross-process mutation authority.
            case .workbookArchive:
                workbookParents.insert(source.deletingLastPathComponent())
            }
        }

        for parent in workbookParents {
            let descriptor = try openDirectory(parent)
            Darwin.close(descriptor)
            let children = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for bundle in children
            where bundle.pathExtension.lowercased()
                == ONTGenotypeResultBundle.directoryExtension {
                var information = stat()
                guard Darwin.lstat(bundle.path, &information) == 0,
                      information.st_mode & S_IFMT == S_IFDIR else {
                    continue
                }
                let lock = ONTGenotypeBundlePublicationLock.lockURL(
                    for: bundle
                )
                targetsByPath[lock.standardizedFileURL.path] = .workbook(
                    bundle: bundle,
                    lock: lock
                )
            }
        }

        var runLocks: [OwnedRunLock] = []
        var workbookLocks: [ONTGenotypeBundlePublicationLock] = []
        do {
            for target in targetsByPath.values.sorted(by: {
                $0.lockURL.path < $1.lockURL.path
            }) {
                switch target {
                case .run(let lockURL):
                    let lock = try OwnedRunLock.acquire(at: lockURL)
                    runLocks.append(lock)
                case .workbook(let bundle, _):
                    let lock = try ONTGenotypeBundlePublicationLock.acquire(
                        for: bundle,
                        blocking: false,
                        createIfMissing: true
                    )
                    workbookLocks.append(lock)
                }
            }
        } catch {
            workbookLocks.reversed().forEach { $0.release() }
            runLocks.reversed().forEach { $0.release() }
            throw error
        }
        return ProductionLockLease(
            runLocks: runLocks,
            workbookLocks: workbookLocks
        )
    }

    private func record(
        for item: ProjectStorageCleanupJournal.Item,
        authority: Authority,
        state: ProjectStorageCleanupDispositionRecord.State,
        quarantineRelativePath: String? = nil,
        quarantineIdentity: FileSystemObjectIdentity? = nil,
        trashDestinationPath: String? = nil,
        reason: String? = nil
    ) -> ProjectStorageCleanupDispositionRecord {
        .init(
            cleanupID: authority.journal.cleanupID,
            projectIdentity: authority.journal.projectIdentity,
            itemID: item.id,
            sourceRelativePath: item.sourceRelativePath,
            sourceIdentity: item.sourceIdentity,
            state: state,
            quarantineRelativePath: quarantineRelativePath,
            quarantineIdentity: quarantineIdentity,
            trashDestinationPath: trashDestinationPath,
            reason: reason,
            recordedAt: operations.now()
        )
    }

    private func terminalRecord(
        for itemID: UUID,
        in records: [ProjectStorageCleanupDispositionRecord]
    ) -> ProjectStorageCleanupDispositionRecord? {
        records.last { $0.itemID == itemID && $0.state.isTerminal }
    }

    private func quarantineLeaf(cleanupID: UUID, itemID: UUID) -> String {
        ".lungfish-trash-pending-"
            + cleanupID.uuidString.lowercased()
            + "-" + itemID.uuidString.lowercased()
    }

    private func deterministicQuarantineRelativePath(
        for item: ProjectStorageCleanupJournal.Item,
        authority: Authority
    ) -> String {
        let source = authority.project.appendingPathComponent(
            item.sourceRelativePath
        )
        return relativePath(
            source.deletingLastPathComponent().appendingPathComponent(
                quarantineLeaf(
                    cleanupID: authority.journal.cleanupID,
                    itemID: item.id
                )
            ),
            under: authority.project
        )
    }

    private func relativePath(_ url: URL, under root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        do {
            return try NoFollowFileSystem.openDirectoryHierarchy(url)
        } catch {
            throw ProjectStorageCleanupExecutionError.unsafeAuthority(url.path)
        }
    }

    private func identity(
        _ name: String,
        in directory: Int32
    ) throws -> FileSystemObjectIdentity {
        guard let value = try identityIfPresent(name, in: directory) else {
            throw ProjectStorageCleanupExecutionError.stateCorrupt(
                "missing expected filesystem object"
            )
        }
        return value
    }

    private func identityIfPresent(
        _ name: String,
        in directory: Int32
    ) throws -> FileSystemObjectIdentity? {
        try objectIfPresent(name, in: directory)?.identity
    }

    private struct FileSystemObject {
        let identity: FileSystemObjectIdentity
        let isDirectory: Bool
    }

    private func objectIfPresent(
        _ name: String,
        in directory: Int32
    ) throws -> FileSystemObject? {
        var information = stat()
        let status = name.withCString {
            Darwin.fstatat(directory, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw ProjectStorageCleanupExecutionError.systemFailure(
                path: name,
                operation: "inspect filesystem object",
                code: errno
            )
        }
        return FileSystemObject(
            identity: FileSystemObjectIdentity(from: information),
            isDirectory: information.st_mode & S_IFMT == S_IFDIR
        )
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32,
        path: URL
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemFailure(path, "write")
                }
                guard count > 0 else {
                    throw ProjectStorageCleanupExecutionError.systemFailure(
                        path: path.path,
                        operation: "write",
                        code: EIO
                    )
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
    }

    private func nextPublicationSequence(operationURL: URL) -> Int {
        var maximum = 0
        if let names = try? FileManager.default.contentsOfDirectory(
            atPath: operationURL.path
        ) {
            for name in names {
                guard name.hasPrefix("execution-summary-")
                        || name.hasPrefix("execution-provenance-"),
                      name.hasSuffix(".json"),
                      let dash = name.lastIndex(of: "-"),
                      let dot = name.lastIndex(of: "."),
                      dash < dot
                else { continue }
                let digits = name[name.index(after: dash)..<dot]
                maximum = max(maximum, Int(digits) ?? 0)
            }
        }
        return maximum + 1
    }

    private func fileDescriptor(
        _ url: URL,
        data: Data,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: sha256(data),
            fileSize: UInt64(data.count),
            format: .json,
            role: role
        )
    }

    private func stateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func stateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func errorDetail(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) code \(value.code): "
            + value.localizedDescription
    }

    private func systemFailure(
        _ url: URL,
        _ operation: String
    ) -> ProjectStorageCleanupExecutionError {
        .systemFailure(
            path: url.path,
            operation: operation,
            code: errno
        )
    }
}

actor ProjectStorageCleanupIdentityGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    static let shared = ProjectStorageCleanupIdentityGate()

    private var held: Set<FileSystemObjectIdentity> = []
    private var waiters: [FileSystemObjectIdentity: [Waiter]] = [:]

    func acquire(_ identity: FileSystemObjectIdentity) async throws {
        try Task.checkCancellation()
        if !held.contains(identity) {
            held.insert(identity)
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[identity, default: []].append(
                    Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    identity: identity,
                    waiterID: waiterID
                )
            }
        }
        guard acquired else { throw CancellationError() }
        guard !Task.isCancelled else {
            release(identity)
            throw CancellationError()
        }
    }

    func release(_ identity: FileSystemObjectIdentity) {
        if var queued = waiters[identity], !queued.isEmpty {
            let waiter = queued.removeFirst()
            waiters[identity] = queued.isEmpty ? nil : queued
            waiter.continuation.resume(returning: true)
        } else {
            held.remove(identity)
        }
    }

    private func cancelWaiter(
        identity: FileSystemObjectIdentity,
        waiterID: UUID
    ) {
        guard var queued = waiters[identity],
              let index = queued.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }
        let waiter = queued.remove(at: index)
        waiters[identity] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }
}
