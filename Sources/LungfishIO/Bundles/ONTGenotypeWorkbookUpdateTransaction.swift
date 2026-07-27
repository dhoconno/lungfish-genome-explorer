import CryptoKit
import Darwin
import Foundation

public enum ONTGenotypeWorkbookUpdateTransactionPhase: String, Codable, Sendable {
    case prepared
    case rollingBack
    case rollbackFailed
    case ambiguous
}

public struct ONTGenotypeWorkbookUpdateFileDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(path: String, sizeBytes: Int64, sha256: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct ONTGenotypeWorkbookUpdateDirectoryIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64

    public init(path: String, device: UInt64, inode: UInt64) {
        self.path = path
        self.device = device
        self.inode = inode
    }
}

public struct ONTGenotypeWorkbookUpdateTransaction: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: String
    public let finalBundlePath: String
    public let stagingBundlePath: String
    public let transactionRootPath: String
    public let rotationTemporaryPath: String
    public let publicationMode: String
    public let workflowName: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let durableReplayArgv: [String]
    public let resolvedOptions: [String: String]
    public let runtimeIdentity: [String: String]
    public let createdAt: Date
    public let oldManifest: ONTGenotypeWorkbookUpdateFileDescriptor
    public let newManifest: ONTGenotypeWorkbookUpdateFileDescriptor
    public let oldCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
    public let newCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
    public let oldGenerationIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let newGenerationIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let transactionRootIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let finalParentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let attestationID: String?
    public var phase: ONTGenotypeWorkbookUpdateTransactionPhase

    public init(
        schemaVersion: Int = 5,
        transactionID: String,
        finalBundlePath: String,
        stagingBundlePath: String,
        transactionRootPath: String,
        rotationTemporaryPath: String,
        publicationMode: String = "atomic-swap-or-exfat-journaled-three-rename-v2",
        workflowName: String,
        toolName: String,
        toolVersion: String,
        argv: [String],
        durableReplayArgv: [String],
        resolvedOptions: [String: String],
        runtimeIdentity: [String: String],
        createdAt: Date = Date(),
        oldManifest: ONTGenotypeWorkbookUpdateFileDescriptor,
        newManifest: ONTGenotypeWorkbookUpdateFileDescriptor,
        oldCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor,
        newCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor,
        oldGenerationIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        newGenerationIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        transactionRootIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        finalParentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        attestationID: String? = nil,
        phase: ONTGenotypeWorkbookUpdateTransactionPhase = .prepared
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.finalBundlePath = finalBundlePath
        self.stagingBundlePath = stagingBundlePath
        self.transactionRootPath = transactionRootPath
        self.rotationTemporaryPath = rotationTemporaryPath
        self.publicationMode = publicationMode
        self.workflowName = workflowName
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.createdAt = createdAt
        self.oldManifest = oldManifest
        self.newManifest = newManifest
        self.oldCurrentWorkbook = oldCurrentWorkbook
        self.newCurrentWorkbook = newCurrentWorkbook
        self.oldGenerationIdentity = oldGenerationIdentity
        self.newGenerationIdentity = newGenerationIdentity
        self.transactionRootIdentity = transactionRootIdentity
        self.finalParentIdentity = finalParentIdentity
        self.attestationID = attestationID
        self.phase = phase
    }
}

public enum ONTGenotypeWorkbookUpdateRecoveryError: Error, LocalizedError, Sendable {
    case unsafeLock(String)
    case lockHeld(String)
    case systemFailure(String, Int32)
    case unsafeMarker(String)
    case recoveryRequired(String)
    case invalidTransaction(String)
    case ambiguousTransaction(String)
    case currentWorkbookIntegrity(String)
    case cleanupPendingWarning(
        quarantinePath: String,
        retryState: String,
        warningPath: String,
        reason: String
    )

    public var errorDescription: String? {
        switch self {
        case .unsafeLock(let path): return "Workbook publication lock is unsafe: \(path)"
        case .lockHeld(let path): return "Workbook publication lock is already held: \(path)"
        case .systemFailure(let path, let code): return "Workbook transaction failed at \(path) (errno \(code))."
        case .unsafeMarker(let path): return "Workbook transaction marker is unsafe: \(path)"
        case .recoveryRequired(let path):
            return "Workbook transaction recovery is required before the bundle can be used: \(path)"
        case .invalidTransaction(let message): return "Workbook transaction marker is invalid: \(message)"
        case .ambiguousTransaction(let message): return "Workbook transaction recovery is ambiguous: \(message)"
        case .currentWorkbookIntegrity(let message): return "The current workbook failed integrity validation: \(message)"
        case .cleanupPendingWarning(
            let quarantinePath,
            let retryState,
            let warningPath,
            let reason
        ):
            return "Workbook cleanup retained \(quarantinePath) in \(retryState) retry state. Warning: \(warningPath). \(reason)"
        }
    }
}

public typealias ONTGenotypeAtomicRenamePrimitive = @Sendable (
    _ sourcePath: String,
    _ destinationPath: String,
    _ flags: UInt32
) -> Int32

public typealias ONTGenotypeDirectoryRenamePrimitive = @Sendable (
    _ sourceParentDescriptor: Int32,
    _ sourceName: String,
    _ destinationParentDescriptor: Int32,
    _ destinationName: String,
    _ flags: UInt32
) -> Int32

public final class ONTGenotypeBundlePublicationLock: @unchecked Sendable {
    public let lockURL: URL
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(lockURL: URL, descriptor: Int32) {
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    public static func lockURL(for bundleURL: URL) -> URL {
        let bundle = bundleURL.standardizedFileURL
        return bundle.deletingLastPathComponent().appendingPathComponent(
            ".\(bundle.lastPathComponent).workbook-publication.lock"
        )
    }

    public static func acquire(
        for bundleURL: URL,
        blocking: Bool = false,
        createIfMissing: Bool = true
    ) throws -> ONTGenotypeBundlePublicationLock {
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
        defer { Darwin.close(parentDescriptor) }
        let lockURL = lockURL(for: bundleURL)
        let openFlags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (createIfMissing ? O_CREAT : 0)
        let descriptor = lockURL.lastPathComponent.withCString {
            Darwin.openat(parentDescriptor, $0, openFlags, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeLock(lockURL.path) }
            if !createIfMissing, errno == ENOENT || errno == EACCES || errno == EROFS {
                throw ONTGenotypeWorkbookUpdateRecoveryError.recoveryRequired(lockURL.path)
            }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(lockURL.path, errno)
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeLock(lockURL.path)
        }
        let lockOperation = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
        guard flock(descriptor, lockOperation) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw ONTGenotypeWorkbookUpdateRecoveryError.lockHeld(lockURL.path)
            }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(lockURL.path, code)
        }
        return ONTGenotypeBundlePublicationLock(lockURL: lockURL, descriptor: descriptor)
    }

    public func release() {
        let value = stateLock.withLock { () -> Int32 in
            defer { descriptor = -1 }
            return descriptor
        }
        guard value >= 0 else { return }
        _ = flock(value, LOCK_UN)
        Darwin.close(value)
    }

    deinit { release() }
}

public enum ONTGenotypeWorkbookUpdateRecovery {
    private struct AttestationClaim: Codable, Equatable {
        let schemaVersion: Int
        let transactionID: String
        let finalBundlePath: String
        let stagingBundlePath: String
        let transactionRootPath: String
        let rotationTemporaryPath: String
        let publicationMode: String
        let workflowName: String
        let toolName: String
        let toolVersion: String
        let argv: [String]
        let durableReplayArgv: [String]
        let resolvedOptions: [String: String]
        let runtimeIdentity: [String: String]
        let createdAt: Date
        let oldManifest: ONTGenotypeWorkbookUpdateFileDescriptor
        let newManifest: ONTGenotypeWorkbookUpdateFileDescriptor
        let oldCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
        let newCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
        let oldGenerationIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
        let newGenerationIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
        let transactionRootIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
        let finalParentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    }

    private struct AttestationRecord: Codable, Equatable {
        let schemaVersion: Int
        let attestationID: String
        let nonce: String
        let claim: AttestationClaim
    }

    private struct FileWitness: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let sha256: String
    }

    private struct RecoveryAuthority {
        let transaction: ONTGenotypeWorkbookUpdateTransaction
        let markerURL: URL?
        let markerWitness: FileWitness?
        let attestationWitness: FileWitness
    }

    private struct Receipt: Codable {
        struct File: Codable {
            let role: String
            let descriptor: ONTGenotypeWorkbookUpdateFileDescriptor
        }

        let schemaVersion: Int
        let transaction: ONTGenotypeWorkbookUpdateTransaction
        let action: String
        let startedAt: Date
        let completedAt: Date
        let wallTimeSeconds: Double
        let exitStatus: Int
        let stderr: String
        let inputs: [File]
        let outputs: [File]
        let detail: String
    }

    public static func markerURL(for bundleURL: URL) -> URL {
        let bundle = bundleURL.standardizedFileURL
        if let discovered = try? discoveredMarkerURLs(for: bundle), discovered.count == 1 {
            return discovered[0]
        }
        return bundle.deletingLastPathComponent().appendingPathComponent(
            ".\(bundleURL.lastPathComponent).workbook-update-transaction.json"
        )
    }

    private static func markerURL(
        for transaction: ONTGenotypeWorkbookUpdateTransaction,
        bundleURL: URL
    ) -> URL {
        bundleURL.standardizedFileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(bundleURL.lastPathComponent).workbook-update-transaction-\(transaction.transactionID).json"
        )
    }

    private static func discoveredMarkerURLs(for bundleURL: URL) throws -> [URL] {
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        let prefix = ".\(bundle.lastPathComponent).workbook-update-transaction-"
        var urls = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        let legacy = parent.appendingPathComponent(
            ".\(bundle.lastPathComponent).workbook-update-transaction.json"
        )
        if FileManager.default.fileExists(atPath: legacy.path) { urls.append(legacy) }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func transactionMarkerHintCount(for bundleURL: URL) throws -> Int {
        try discoveredMarkerURLs(for: bundleURL).count
    }

    public static func defaultAttestationRootURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The user Application Support directory is unavailable."
            )
        }
        return applicationSupport
            .appendingPathComponent("Lungfish", isDirectory: true)
            .appendingPathComponent("workbook-publication-attestations", isDirectory: true)
    }

    public static func createAttestation(
        for transaction: ONTGenotypeWorkbookUpdateTransaction,
        attestationRootURL: URL? = nil
    ) throws -> ONTGenotypeWorkbookUpdateTransaction {
        guard transaction.schemaVersion == 5, transaction.attestationID == nil else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Only an unattested schema-v5 transaction can be attested."
            )
        }
        let attestationID = UUID().uuidString
        let root = try prepareAttestationRoot(attestationRootURL)
        let recordURL = root.appendingPathComponent("\(attestationID).json")
        let record = AttestationRecord(
            schemaVersion: 1,
            attestationID: attestationID,
            nonce: UUID().uuidString,
            claim: claim(for: transaction)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writeExclusiveAttestation(try encoder.encode(record), to: recordURL, root: root)
        return ONTGenotypeWorkbookUpdateTransaction(
            schemaVersion: transaction.schemaVersion,
            transactionID: transaction.transactionID,
            finalBundlePath: transaction.finalBundlePath,
            stagingBundlePath: transaction.stagingBundlePath,
            transactionRootPath: transaction.transactionRootPath,
            rotationTemporaryPath: transaction.rotationTemporaryPath,
            publicationMode: transaction.publicationMode,
            workflowName: transaction.workflowName,
            toolName: transaction.toolName,
            toolVersion: transaction.toolVersion,
            argv: transaction.argv,
            durableReplayArgv: transaction.durableReplayArgv,
            resolvedOptions: transaction.resolvedOptions,
            runtimeIdentity: transaction.runtimeIdentity,
            createdAt: transaction.createdAt,
            oldManifest: transaction.oldManifest,
            newManifest: transaction.newManifest,
            oldCurrentWorkbook: transaction.oldCurrentWorkbook,
            newCurrentWorkbook: transaction.newCurrentWorkbook,
            oldGenerationIdentity: transaction.oldGenerationIdentity,
            newGenerationIdentity: transaction.newGenerationIdentity,
            transactionRootIdentity: transaction.transactionRootIdentity,
            finalParentIdentity: transaction.finalParentIdentity,
            attestationID: attestationID,
            phase: transaction.phase
        )
    }

    public static func descriptor(for url: URL, path: String) throws -> ONTGenotypeWorkbookUpdateFileDescriptor {
        let measured = try measureRegularFileNoFollow(url)
        return ONTGenotypeWorkbookUpdateFileDescriptor(
            path: path,
            sizeBytes: measured.size,
            sha256: measured.sha256
        )
    }

    public static func descriptor(for data: Data, path: String) -> ONTGenotypeWorkbookUpdateFileDescriptor {
        ONTGenotypeWorkbookUpdateFileDescriptor(
            path: path,
            sizeBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    public static func directoryIdentity(
        for url: URL,
        path: String
    ) throws -> ONTGenotypeWorkbookUpdateDirectoryIdentity {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "journaled generation is not a real directory: \(url.path)"
            )
        }
        return ONTGenotypeWorkbookUpdateDirectoryIdentity(
            path: path,
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    public static func write(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        attestationRootURL: URL? = nil,
        atomicRenamePrimitive: ONTGenotypeAtomicRenamePrimitive? = nil,
        markerWriteFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws {
        try validate(transaction, for: bundleURL)
        _ = try requireAttestationRecord(transaction, attestationRootURL: attestationRootURL)
        guard try discoveredMarkerURLs(for: bundleURL).isEmpty else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(
                markerURL(for: bundleURL).path
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let exactMarkerURL = markerURL(for: transaction, bundleURL: bundleURL)
        var markerWasCreated = false
        do {
            try atomicWriteNoFollow(
                try encoder.encode(transaction),
                to: exactMarkerURL,
                renamePrimitive: atomicRenamePrimitive,
                writeFailureInjector: markerWriteFailureInjector,
                fileCreationObserver: { markerWasCreated = true }
            )
        } catch {
            if markerWasCreated {
                throw ONTGenotypeWorkbookUpdateRecoveryError.recoveryRequired(exactMarkerURL.path)
            }
            throw error
        }
    }

    public static func removeUnpublishedAttestation(
        for transaction: ONTGenotypeWorkbookUpdateTransaction,
        attestationRootURL: URL? = nil
    ) throws {
        let witness = try requireAttestationRecord(
            transaction,
            attestationRootURL: attestationRootURL
        )
        let url = try attestationURL(
            for: transaction,
            attestationRootURL: attestationRootURL
        )
        try unlinkExact(url, expected: witness)
    }

    public static func removeMarker(for bundleURL: URL) throws {
        let marker = markerURL(for: bundleURL)
        var info = stat()
        if Darwin.lstat(marker.path, &info) != 0 {
            if errno == ENOENT { return }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(marker.path, errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(marker.path)
        }
        guard Darwin.unlink(marker.path) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(marker.path, errno)
        }
        try syncDirectory(marker.deletingLastPathComponent())
    }

    public static func finalizeCommittedTransactionAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        attestationRootURL: URL? = nil,
        cleanupFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws {
        let authority = try loadRecoveryAuthority(
            for: bundleURL,
            attestationRootURL: attestationRootURL
        )
        guard authority.transaction.transactionID == transaction.transactionID,
              authority.transaction.attestationID == transaction.attestationID,
              authority.transaction.phase == transaction.phase else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The live workbook transaction marker changed before finalization; no cleanup was performed."
            )
        }
        try validateTransactionRootIfPresent(transaction)
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        guard try generationState(at: final, transaction: transaction) == .committedNew,
              try generationState(at: staging, transaction: transaction) == .old else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Cannot finalize a workbook transaction whose committed and prior generations do not match the journal."
            )
        }
        try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
        try prepareProvenTransactionRootCleanup(
            transaction,
            decision: .committed,
            failureInjector: cleanupFailureInjector
        )
        try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
        try removeMarkerAndAttestation(
            authority,
            for: bundleURL,
            attestationRootURL: attestationRootURL,
            cleanupFailureInjector: cleanupFailureInjector
        )
        try completeProvenTransactionRootCleanup(
            transaction,
            for: bundleURL,
            failureInjector: cleanupFailureInjector
        )
    }

    public static func discardPreparedTransactionAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        attestationRootURL: URL? = nil,
        cleanupFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws {
        let authority = try loadRecoveryAuthority(
            for: bundleURL,
            attestationRootURL: attestationRootURL
        )
        guard authority.transaction.transactionID == transaction.transactionID,
              authority.transaction.attestationID == transaction.attestationID,
              authority.transaction.phase == transaction.phase else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The live workbook transaction marker changed before discard; no cleanup was performed."
            )
        }
        try validatePreparedDirectoryIdentitiesAssumingLock(transaction, for: bundleURL)
        try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
        try prepareProvenTransactionRootCleanup(
            transaction,
            decision: .preparedDiscard,
            failureInjector: cleanupFailureInjector
        )
        try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
        try removeMarkerAndAttestation(
            authority,
            for: bundleURL,
            attestationRootURL: attestationRootURL,
            cleanupFailureInjector: cleanupFailureInjector
        )
        try completeProvenTransactionRootCleanup(
            transaction,
            for: bundleURL,
            failureInjector: cleanupFailureInjector
        )
    }

    public static func recoverIfNeededAssumingLock(
        for bundleURL: URL,
        attestationRootURL: URL? = nil,
        cleanupFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws {
        if try recoverCleanupStateIfPresent(
            for: bundleURL,
            attestationRootURL: attestationRootURL,
            failureInjector: cleanupFailureInjector
        ) {
            return
        }
        guard let authority = try loadRecoveryAuthorityIfPresent(
            for: bundleURL,
            attestationRootURL: attestationRootURL
        ) else { return }
        let transaction = authority.transaction
        try validateTransactionRootIfPresent(transaction)
        if try normalizeInterruptedRotation(
            transaction,
            authority: authority,
            for: bundleURL,
            attestationRootURL: attestationRootURL
        ) {
            try recoverIfNeededAssumingLock(
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            return
        }
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        let finalState = try generationState(at: final, transaction: transaction)
        let stagingState = try generationState(at: staging, transaction: transaction)

        if (finalState == .oldWorkbookEdited && stagingState == .committedNewWorkbookEdited)
            || (finalState == .committedNewWorkbookEdited && stagingState == .oldWorkbookEdited) {
            throw try ambiguous(
                transaction,
                detail: "Both workbook generations were edited; both were preserved for explicit user resolution."
            )
        }
        if finalState == .oldWorkbookEdited,
           (stagingState == .committedNew || stagingState == .committedNewWorkbookEdited) {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .manualSaveWinner,
                failureInjector: cleanupFailureInjector
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try writeReceipt(
                transaction,
                action: "preserved-manually-edited-prior-generation",
                detail: "The prior generation was restored after a manual-save conflict; the generated revision was discarded."
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        if (finalState == .old || finalState == .oldWorkbookEdited), stagingState == .preparedNew {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .preparedDiscard,
                failureInjector: cleanupFailureInjector
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try writeReceipt(transaction, action: "discarded-unpublished-staging", detail: "Final generation remained unchanged.")
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        if finalState == .preparedNew, stagingState == .old {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try exchange(
                final,
                expectedLHS: transaction.newGenerationIdentity,
                staging,
                expectedRHS: transaction.oldGenerationIdentity,
                temporary: URL(
                    fileURLWithPath: transaction.rotationTemporaryPath,
                    isDirectory: true
                ),
                transaction: transaction
            )
            guard try generationState(at: final, transaction: transaction) == .old else {
                throw try ambiguous(transaction, detail: "Rollback exchange did not restore the prior generation.")
            }
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .rollback,
                failureInjector: cleanupFailureInjector
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try writeReceipt(transaction, action: "restored-prior-generation", detail: "Recovered an interrupted pre-manifest workbook publication.")
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        if (finalState == .committedNew || finalState == .committedNewWorkbookEdited),
           stagingState == .oldWorkbookEdited {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try exchange(
                final,
                expectedLHS: transaction.newGenerationIdentity,
                staging,
                expectedRHS: transaction.oldGenerationIdentity,
                temporary: URL(
                    fileURLWithPath: transaction.rotationTemporaryPath,
                    isDirectory: true
                ),
                transaction: transaction
            )
            guard try generationState(at: final, transaction: transaction) == .oldWorkbookEdited else {
                throw try ambiguous(
                    transaction,
                    detail: "Rollback did not restore the manually edited prior workbook generation."
                )
            }
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .manualSaveWinner,
                failureInjector: cleanupFailureInjector
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try writeReceipt(
                transaction,
                action: "restored-manually-edited-prior-generation",
                detail: "A manual save to the retired workbook generation won the publication conflict; the generated revision was discarded."
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        if (finalState == .committedNew || finalState == .committedNewWorkbookEdited),
           stagingState == .old {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .committed,
                failureInjector: cleanupFailureInjector
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try writeReceipt(transaction, action: "finished-committed-cleanup", detail: "The new manifest and workbook were already durable.")
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        if (finalState == .committedNew || finalState == .committedNewWorkbookEdited), stagingState == .missing {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .committed,
                failureInjector: cleanupFailureInjector
            )
            try writeReceipt(transaction, action: "finished-committed-marker-cleanup", detail: "The prior generation had already been retired.")
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        if (finalState == .old || finalState == .oldWorkbookEdited),
           !FileManager.default.fileExists(atPath: staging.path) {
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try prepareProvenTransactionRootCleanup(
                transaction,
                decision: .rollback,
                failureInjector: cleanupFailureInjector
            )
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try writeReceipt(transaction, action: "finished-rollback-cleanup", detail: "The prior generation was already restored.")
            try requireAuthorityUnchanged(authority, for: bundleURL, attestationRootURL: attestationRootURL)
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: cleanupFailureInjector
            )
            try completeProvenTransactionRootCleanup(
                transaction,
                for: bundleURL,
                failureInjector: cleanupFailureInjector
            )
            return
        }
        throw try ambiguous(
            transaction,
            detail: "final=\(finalState.rawValue), staging=\(stagingState.rawValue); both generations were preserved"
        )
    }

    public static func recoveryAuthorityExists(for bundleURL: URL) throws -> Bool {
        if try !ONTGenotypeWorkbookCleanupStateStore.states(
            for: bundleURL.standardizedFileURL
        ).isEmpty {
            return true
        }
        return try loadRecoveryAuthorityIfPresent(
            for: bundleURL.standardizedFileURL,
            attestationRootURL: nil
        ) != nil
    }

    public static func validateCurrentWorkbook(
        in bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest
    ) throws {
        guard let currentPath = manifest.currentWorkbookPath else { return }
        guard let revision = manifest.workbookRevisions?.last(where: { $0.path == currentPath }) else { return }
        let url = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundleURL)
        let actual = try descriptor(for: url, path: currentPath)
        guard actual.sizeBytes == revision.sizeBytes,
              actual.sha256.caseInsensitiveCompare(revision.sha256) == .orderedSame else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.currentWorkbookIntegrity(
                "\(currentPath) does not match revision \(revision.id) (expected \(revision.sizeBytes) bytes / \(revision.sha256), got \(actual.sizeBytes) bytes / \(actual.sha256))."
            )
        }
    }

    private static func normalizeInterruptedRotation(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        authority: RecoveryAuthority,
        for bundleURL: URL,
        attestationRootURL: URL?
    ) throws -> Bool {
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        let temporary = URL(fileURLWithPath: transaction.rotationTemporaryPath, isDirectory: true)
        let finalState = try generationState(at: final, transaction: transaction)
        let stagingState = try generationState(at: staging, transaction: transaction)
        let temporaryState = try generationState(at: temporary, transaction: transaction)
        guard temporaryState != .missing else { return false }

        func move(
            _ source: URL,
            expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
            to destination: URL
        ) throws {
            try requireAuthorityUnchanged(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL
            )
            try moveDirectoryNoReplace(
                source,
                expected: expected,
                to: destination,
                transaction: transaction
            )
        }

        if (finalState == .old || finalState == .oldWorkbookEdited),
           stagingState == .missing,
           temporaryState == .preparedNew {
            try move(temporary, expected: transaction.newGenerationIdentity, to: staging)
            return true
        }
        if finalState == .missing,
           (stagingState == .old || stagingState == .oldWorkbookEdited),
           temporaryState == .preparedNew {
            try move(staging, expected: transaction.oldGenerationIdentity, to: final)
            try move(temporary, expected: transaction.newGenerationIdentity, to: staging)
            return true
        }
        if (finalState == .preparedNew || finalState == .committedNew || finalState == .committedNewWorkbookEdited),
           stagingState == .missing,
           (temporaryState == .old || temporaryState == .oldWorkbookEdited) {
            try move(temporary, expected: transaction.oldGenerationIdentity, to: staging)
            return true
        }
        if finalState == .missing,
           stagingState == .preparedNew,
           (temporaryState == .old || temporaryState == .oldWorkbookEdited) {
            try move(temporary, expected: transaction.oldGenerationIdentity, to: final)
            return true
        }
        throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
            "Interrupted workbook directory rotation is ambiguous; all generations were preserved."
        )
    }

    private static func moveDirectoryNoReplace(
        _ source: URL,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        to destination: URL,
        transaction: ONTGenotypeWorkbookUpdateTransaction,
        renamePrimitive: ONTGenotypeDirectoryRenamePrimitive? = nil
    ) throws {
        let sourceParentURL = source.deletingLastPathComponent().standardizedFileURL
        let destinationParentURL = destination.deletingLastPathComponent().standardizedFileURL
        let sourceParentIdentity = try boundParentIdentity(
            for: sourceParentURL,
            transaction: transaction
        )
        let destinationParentIdentity = try boundParentIdentity(
            for: destinationParentURL,
            transaction: transaction
        )
        let sourceParent = Darwin.open(
            sourceParentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceParent >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(sourceParentURL.path, errno)
        }
        defer { Darwin.close(sourceParent) }
        let destinationParent = Darwin.open(
            destinationParentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationParent >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(destinationParentURL.path, errno)
        }
        defer { Darwin.close(destinationParent) }
        try requireDirectoryDescriptorIdentity(
            sourceParent,
            expected: sourceParentIdentity,
            role: "rotation source parent"
        )
        try requireDirectoryDescriptorIdentity(
            destinationParent,
            expected: destinationParentIdentity,
            role: "rotation destination parent"
        )
        try requireDirectoryEntryIdentity(
            parentDescriptor: sourceParent,
            name: source.lastPathComponent,
            expected: expected,
            role: "rotation source"
        )
        let rename: ONTGenotypeDirectoryRenamePrimitive = renamePrimitive ?? {
            sourceParent, sourceName, destinationParent, destinationName, flags in
            Darwin.renameatx_np(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName,
                flags
            )
        }
        let exclusiveStatus = rename(
            sourceParent,
            source.lastPathComponent,
            destinationParent,
            destination.lastPathComponent,
            UInt32(RENAME_EXCL)
        )
        if exclusiveStatus != 0 {
            let exclusiveError = errno
            guard exclusiveError == ENOTSUP || exclusiveError == EINVAL else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                    destination.path,
                    exclusiveError
                )
            }
            try requireDirectoryDescriptorIdentity(
                sourceParent,
                expected: sourceParentIdentity,
                role: "rotation source parent"
            )
            try requireDirectoryDescriptorIdentity(
                destinationParent,
                expected: destinationParentIdentity,
                role: "rotation destination parent"
            )
            try requireDirectoryEntryIdentity(
                parentDescriptor: sourceParent,
                name: source.lastPathComponent,
                expected: expected,
                role: "rotation source"
            )
            var destinationInfo = stat()
            let destinationInspect = destination.lastPathComponent.withCString {
                Darwin.fstatat(destinationParent, $0, &destinationInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard destinationInspect != 0, errno == ENOENT else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Rotation destination is no longer absent; all generations were preserved: \(destination.path)"
                )
            }
            // On filesystems without RENAME_EXCL, the stable publication lock and the
            // app-owned 0700 transaction root define the cooperative-writer boundary.
            // Hostile same-UID replacement in the final check/rename interval cannot be
            // prevented by Darwin on ExFAT and is intentionally outside this guarantee.
            if rename(
                sourceParent,
                source.lastPathComponent,
                destinationParent,
                destination.lastPathComponent,
                0
            ) != 0 {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                    destination.path,
                    errno
                )
            }
        }
        try requireDirectoryEntryIdentity(
            parentDescriptor: destinationParent,
            name: destination.lastPathComponent,
            expected: expected,
            role: "rotation destination"
        )
        var sourceInfo = stat()
        let sourceStatus = source.lastPathComponent.withCString {
            Darwin.fstatat(sourceParent, $0, &sourceInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceStatus != 0, errno == ENOENT else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Rotation source remained visible after publication."
            )
        }
        guard Darwin.fsync(destinationParent) == 0,
              sourceParent == destinationParent || Darwin.fsync(sourceParent) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(destination.path, errno)
        }
    }

    private enum GenerationState: String {
        case old
        case oldWorkbookEdited
        case preparedNew
        case committedNew
        case committedNewWorkbookEdited
        case missing
        case ambiguous
    }

    private static func generationState(
        at bundleURL: URL,
        transaction: ONTGenotypeWorkbookUpdateTransaction
    ) throws -> GenerationState {
        guard let actualIdentity = try directoryIdentityIfPresent(at: bundleURL) else { return .missing }
        let isOldGeneration = identity(actualIdentity, matches: transaction.oldGenerationIdentity)
        let isNewGeneration = identity(actualIdentity, matches: transaction.newGenerationIdentity)
        guard isOldGeneration || isNewGeneration else { return .ambiguous }
        let manifestURL = bundleURL.appendingPathComponent(transaction.oldManifest.path)
        let oldManifest = matches(manifestURL, transaction.oldManifest)
        let newManifest = matches(manifestURL, transaction.newManifest)
        let oldWorkbook = matches(
            bundleURL.appendingPathComponent(transaction.oldCurrentWorkbook.path),
            transaction.oldCurrentWorkbook
        )
        let newWorkbook = matches(
            bundleURL.appendingPathComponent(transaction.newCurrentWorkbook.path),
            transaction.newCurrentWorkbook
        )
        if isOldGeneration, oldManifest && oldWorkbook { return .old }
        if isOldGeneration, oldManifest { return .oldWorkbookEdited }
        if isNewGeneration, oldManifest && newWorkbook { return .preparedNew }
        if isNewGeneration, newManifest && newWorkbook { return .committedNew }
        if isNewGeneration, newManifest { return .committedNewWorkbookEdited }
        return .ambiguous
    }

    private static func matches(_ url: URL, _ expected: ONTGenotypeWorkbookUpdateFileDescriptor) -> Bool {
        guard let actual = try? descriptor(for: url, path: expected.path) else { return false }
        return actual.sizeBytes == expected.sizeBytes
            && actual.sha256.caseInsensitiveCompare(expected.sha256) == .orderedSame
    }

    private static func validate(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL
    ) throws {
        let expectedFinalPath = NSString(string: transaction.finalBundlePath).standardizingPath
        let suppliedFinalPath = NSString(string: bundleURL.path).standardizingPath
        let final = URL(fileURLWithPath: expectedFinalPath, isDirectory: true)
        guard transaction.schemaVersion == 5,
              expectedFinalPath == suppliedFinalPath,
              transaction.oldManifest.path == ONTGenotypeResultBundleManifest.filename,
              transaction.newManifest.path == ONTGenotypeResultBundleManifest.filename,
              transaction.oldCurrentWorkbook.path == transaction.newCurrentWorkbook.path,
              transaction.oldGenerationIdentity.path == transaction.finalBundlePath,
              transaction.newGenerationIdentity.path == transaction.stagingBundlePath,
              transaction.transactionRootIdentity.path == transaction.transactionRootPath,
              transaction.finalParentIdentity.path == final.deletingLastPathComponent().path,
              transaction.publicationMode == "atomic-swap-or-exfat-journaled-three-rename-v2",
              let attestationID = transaction.attestationID,
              let parsedAttestationID = UUID(uuidString: attestationID),
              parsedAttestationID.uuidString == attestationID else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(markerURL(for: bundleURL).path)
        }
        let parent = final.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true).standardizedFileURL
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true).standardizedFileURL
        let rotationTemporary = URL(
            fileURLWithPath: transaction.rotationTemporaryPath,
            isDirectory: true
        ).standardizedFileURL
        guard root.deletingLastPathComponent() == parent,
              staging.deletingLastPathComponent() == root,
              rotationTemporary.deletingLastPathComponent() == root,
              rotationTemporary.lastPathComponent == ".publication-rotation",
              staging.lastPathComponent == final.lastPathComponent,
              root.lastPathComponent.hasPrefix(".\(final.lastPathComponent).workbook-update-"),
              root.lastPathComponent.hasSuffix(".staging") else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction("staging paths do not match the generated adjacent layout")
        }
        for descriptor in [
            transaction.oldManifest, transaction.newManifest,
            transaction.oldCurrentWorkbook, transaction.newCurrentWorkbook,
        ] {
            let components = NSString(string: descriptor.path).pathComponents
            guard !descriptor.path.hasPrefix("/"),
                  !components.isEmpty,
                  components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction("descriptor path escapes its generation")
            }
        }
    }

    public static func validatePreparedDirectoryIdentitiesAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL
    ) throws {
        try validate(transaction, for: bundleURL)
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true),
            expected: transaction.transactionRootIdentity,
            role: "transaction root"
        )
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true),
            expected: transaction.oldGenerationIdentity,
            role: "prior generation"
        )
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true),
            expected: transaction.newGenerationIdentity,
            role: "prepared generation"
        )
    }

    public static func validateExchangedDirectoryIdentitiesAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL
    ) throws {
        try validate(transaction, for: bundleURL)
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true),
            expected: transaction.transactionRootIdentity,
            role: "transaction root"
        )
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true),
            expected: transaction.newGenerationIdentity,
            role: "prepared generation"
        )
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true),
            expected: transaction.oldGenerationIdentity,
            role: "prior generation"
        )
    }

    public static func validateRecoveryAuthorityAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        attestationRootURL: URL? = nil
    ) throws {
        let authority = try loadRecoveryAuthority(
            for: bundleURL,
            attestationRootURL: attestationRootURL
        )
        guard authority.transaction.transactionID == transaction.transactionID,
              authority.transaction.attestationID == transaction.attestationID,
              authority.transaction.phase == transaction.phase else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The live workbook transaction changed before directory rotation."
            )
        }
        try requireAuthorityUnchanged(
            authority,
            for: bundleURL,
            attestationRootURL: attestationRootURL
        )
        try validateBoundPublicationParents(transaction)
    }

    public static func moveDirectoryNoReplaceAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        source: URL,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        destination: URL,
        attestationRootURL: URL? = nil,
        renamePrimitive: ONTGenotypeDirectoryRenamePrimitive? = nil
    ) throws {
        try validateRecoveryAuthorityAssumingLock(
            transaction,
            for: bundleURL,
            attestationRootURL: attestationRootURL
        )
        try moveDirectoryNoReplace(
            source,
            expected: expected,
            to: destination,
            transaction: transaction,
            renamePrimitive: renamePrimitive
        )
    }

    public static func swapDirectoriesAssumingLock(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        lhs: URL,
        expectedLHS: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        rhs: URL,
        expectedRHS: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        attestationRootURL: URL? = nil,
        renamePrimitive: ONTGenotypeDirectoryRenamePrimitive? = nil
    ) throws -> Bool {
        try validateRecoveryAuthorityAssumingLock(
            transaction,
            for: bundleURL,
            attestationRootURL: attestationRootURL
        )
        return try swapDirectories(
            lhs,
            expectedLHS: expectedLHS,
            rhs,
            expectedRHS: expectedRHS,
            transaction: transaction,
            renamePrimitive: renamePrimitive
        )
    }

    private static func validateTransactionRootIfPresent(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction
    ) throws {
        let root = URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true)
        guard let actual = try directoryIdentityIfPresent(at: root) else { return }
        guard identity(actual, matches: transaction.transactionRootIdentity) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "transaction root identity does not match the journal: \(root.path)"
            )
        }
    }

    private static func swapDirectories(
        _ lhs: URL,
        expectedLHS: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        _ rhs: URL,
        expectedRHS: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        transaction: ONTGenotypeWorkbookUpdateTransaction,
        renamePrimitive: ONTGenotypeDirectoryRenamePrimitive? = nil
    ) throws -> Bool {
        let lhsParentURL = lhs.deletingLastPathComponent().standardizedFileURL
        let rhsParentURL = rhs.deletingLastPathComponent().standardizedFileURL
        let lhsParentIdentity = try boundParentIdentity(for: lhsParentURL, transaction: transaction)
        let rhsParentIdentity = try boundParentIdentity(for: rhsParentURL, transaction: transaction)
        let lhsParent = Darwin.open(lhsParentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lhsParent >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(lhsParentURL.path, errno)
        }
        defer { Darwin.close(lhsParent) }
        let rhsParent = Darwin.open(rhsParentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rhsParent >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(rhsParentURL.path, errno)
        }
        defer { Darwin.close(rhsParent) }
        try requireDirectoryDescriptorIdentity(lhsParent, expected: lhsParentIdentity, role: "exchange lhs parent")
        try requireDirectoryDescriptorIdentity(rhsParent, expected: rhsParentIdentity, role: "exchange rhs parent")
        try requireDirectoryEntryIdentity(
            parentDescriptor: lhsParent,
            name: lhs.lastPathComponent,
            expected: expectedLHS,
            role: "exchange lhs"
        )
        try requireDirectoryEntryIdentity(
            parentDescriptor: rhsParent,
            name: rhs.lastPathComponent,
            expected: expectedRHS,
            role: "exchange rhs"
        )
        let rename: ONTGenotypeDirectoryRenamePrimitive = renamePrimitive ?? {
            sourceParent, sourceName, destinationParent, destinationName, flags in
            Darwin.renameatx_np(sourceParent, sourceName, destinationParent, destinationName, flags)
        }
        if rename(lhsParent, lhs.lastPathComponent, rhsParent, rhs.lastPathComponent, UInt32(RENAME_SWAP)) != 0 {
            let swapError = errno
            if swapError == ENOTSUP || swapError == EINVAL { return false }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(rhs.path, swapError)
        }
        try requireDirectoryEntryIdentity(
            parentDescriptor: lhsParent,
            name: lhs.lastPathComponent,
            expected: expectedRHS,
            role: "exchanged lhs"
        )
        try requireDirectoryEntryIdentity(
            parentDescriptor: rhsParent,
            name: rhs.lastPathComponent,
            expected: expectedLHS,
            role: "exchanged rhs"
        )
        guard Darwin.fsync(lhsParent) == 0,
              lhsParent == rhsParent || Darwin.fsync(rhsParent) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(rhs.path, errno)
        }
        return true
    }

    private static func requireDirectoryIdentity(
        at url: URL,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        role: String
    ) throws {
        guard let actual = try directoryIdentityIfPresent(at: url),
              identity(actual, matches: expected) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "\(role) identity does not match the journal: \(url.path)"
            )
        }
    }

    private static func validateBoundPublicationParents(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction
    ) throws {
        try requireDirectoryIdentity(
            at: URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true),
            expected: transaction.transactionRootIdentity,
            role: "transaction root"
        )
        try requireDirectoryIdentity(
            at: URL(
                fileURLWithPath: transaction.finalParentIdentity.path,
                isDirectory: true
            ),
            expected: transaction.finalParentIdentity,
            role: "final bundle parent"
        )
    }

    private static func boundParentIdentity(
        for url: URL,
        transaction: ONTGenotypeWorkbookUpdateTransaction
    ) throws -> ONTGenotypeWorkbookUpdateDirectoryIdentity {
        let path = url.standardizedFileURL.path
        if path == NSString(string: transaction.transactionRootIdentity.path).standardizingPath {
            return transaction.transactionRootIdentity
        }
        if path == NSString(string: transaction.finalParentIdentity.path).standardizingPath {
            return transaction.finalParentIdentity
        }
        throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
            "directory move parent is not bound by the transaction: \(path)"
        )
    }

    private static func requireDirectoryDescriptorIdentity(
        _ descriptor: Int32,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        role: String
    ) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(info.st_dev)) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "\(role) descriptor identity does not match the journal"
            )
        }
    }

    private static func requireDirectoryEntryIdentity(
        parentDescriptor: Int32,
        name: String,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        role: String
    ) throws {
        var info = stat()
        let status = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(info.st_dev)) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "\(role) identity does not match the journal"
            )
        }
    }

    private static func directoryIdentityIfPresent(
        at url: URL
    ) throws -> ONTGenotypeWorkbookUpdateDirectoryIdentity? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "journaled directory path is not a real directory: \(url.path)"
            )
        }
        return ONTGenotypeWorkbookUpdateDirectoryIdentity(
            path: url.path,
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    private static func identity(
        _ actual: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        matches expected: ONTGenotypeWorkbookUpdateDirectoryIdentity
    ) -> Bool {
        actual.device == expected.device && actual.inode == expected.inode
    }

    private static func ambiguous(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        detail: String
    ) throws -> ONTGenotypeWorkbookUpdateRecoveryError {
        try writeReceipt(transaction, action: "ambiguous-preserved", detail: detail)
        return .ambiguousTransaction(detail)
    }

    private static func prepareProvenTransactionRootCleanup(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        decision: ONTGenotypeWorkbookCleanupDecision,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        let root = URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        guard staging.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              staging.lastPathComponent == final.lastPathComponent,
              root.lastPathComponent.hasPrefix(".\(final.lastPathComponent).workbook-update-"),
              root.lastPathComponent.hasSuffix(".staging") else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction("unsafe transaction cleanup root")
        }
        let parent = root.deletingLastPathComponent()
        let quarantine = ONTGenotypeWorkbookCleanupStateStore.quarantineURL(
            transactionID: transaction.transactionID,
            parent: parent
        )
        let stateURL = ONTGenotypeWorkbookCleanupStateStore.stateURL(
            transactionID: transaction.transactionID,
            bundleURL: final
        )
        let existingStates = try ONTGenotypeWorkbookCleanupStateStore.states(for: final)
            .filter { $0.1.transactionID == transaction.transactionID }
        guard existingStates.count <= 1 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Multiple workbook cleanup states claim transaction \(transaction.transactionID)."
            )
        }
        if let existing = existingStates.first {
            guard existing.0.standardizedFileURL == stateURL.standardizedFileURL,
                  existing.1.decision == decision else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Workbook cleanup decision changed for transaction \(transaction.transactionID)."
                )
            }
            return
        }

        let rootIdentity = try directoryIdentityIfPresent(at: root)
        let quarantineIdentity = try directoryIdentityIfPresent(at: quarantine)
        if let rootIdentity {
            guard identity(rootIdentity, matches: transaction.transactionRootIdentity) else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                    "transaction root identity does not match before cleanup detach: \(root.path)"
                )
            }
            guard quarantineIdentity == nil else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Workbook cleanup quarantine already exists while the transaction root remains."
                )
            }
            try moveDirectoryNoReplace(
                root,
                expected: transaction.transactionRootIdentity,
                to: quarantine,
                transaction: transaction
            )
            try failureInjector?("after-workbook-cleanup-detach-hard-stop")
        } else if let quarantineIdentity {
            guard identity(quarantineIdentity, matches: transaction.transactionRootIdentity) else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Workbook cleanup quarantine identity does not match the transaction root."
                )
            }
        } else {
            // A prior cleanup may have removed the quarantine before retiring
            // recovery authority. There is no retired generation left to delete.
            return
        }

        guard let detachedIdentity = try directoryIdentityIfPresent(at: quarantine),
              identity(detachedIdentity, matches: transaction.transactionRootIdentity) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook cleanup quarantine is unavailable or changed."
            )
        }
        let state = ONTGenotypeWorkbookCleanupState(
            transactionID: transaction.transactionID,
            finalBundlePath: final.path,
            sourceRootPath: root.path,
            quarantinePath: quarantine.path,
            parentIdentity: transaction.finalParentIdentity,
            sourceIdentity: transaction.transactionRootIdentity,
            quarantineIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity(
                path: quarantine.path,
                device: detachedIdentity.device,
                inode: detachedIdentity.inode
            ),
            decision: decision
        )
        try ONTGenotypeWorkbookCleanupStateStore.write(state, at: stateURL)
        try failureInjector?("after-workbook-cleanup-state-durable-hard-stop")
    }

    private static func completeProvenTransactionRootCleanup(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        for bundleURL: URL,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        let states = try ONTGenotypeWorkbookCleanupStateStore.states(for: bundleURL)
            .filter { $0.1.transactionID == transaction.transactionID }
        guard states.count <= 1 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Multiple workbook cleanup states claim transaction \(transaction.transactionID)."
            )
        }
        guard let (stateURL, state) = states.first else { return }
        try ONTGenotypeWorkbookCleanupStateStore.removeQuarantineNoFollow(
            state: state,
            stateURL: stateURL,
            failureInjector: failureInjector
        )
    }

    private static func exchange(
        _ lhs: URL,
        expectedLHS: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        _ rhs: URL,
        expectedRHS: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        temporary: URL,
        transaction: ONTGenotypeWorkbookUpdateTransaction
    ) throws {
        if try !swapDirectories(
            lhs,
            expectedLHS: expectedLHS,
            rhs,
            expectedRHS: expectedRHS,
            transaction: transaction
        ) {
            try moveDirectoryNoReplace(lhs, expected: expectedLHS, to: temporary, transaction: transaction)
            try moveDirectoryNoReplace(rhs, expected: expectedRHS, to: lhs, transaction: transaction)
            try moveDirectoryNoReplace(temporary, expected: expectedLHS, to: rhs, transaction: transaction)
        }
        try requireDirectoryIdentity(at: lhs, expected: expectedRHS, role: "exchanged prior generation")
        try requireDirectoryIdentity(at: rhs, expected: expectedLHS, role: "exchanged prepared generation")
        try syncDirectory(rhs.deletingLastPathComponent())
    }

    private static func writeReceipt(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        action: String,
        detail: String
    ) throws {
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let url = final.deletingLastPathComponent().appendingPathComponent(
            ".\(final.lastPathComponent).workbook-update-recovery-\(transaction.transactionID)-\(UUID().uuidString).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let completedAt = Date()
        let exitStatus = action == "ambiguous-preserved" ? 1 : 0
        try atomicWriteNoFollow(try encoder.encode(Receipt(
            schemaVersion: 1,
            transaction: transaction,
            action: action,
            startedAt: transaction.createdAt,
            completedAt: completedAt,
            wallTimeSeconds: max(0, completedAt.timeIntervalSince(transaction.createdAt)),
            exitStatus: exitStatus,
            stderr: exitStatus == 0 ? "" : detail,
            inputs: [
                Receipt.File(role: "old-manifest", descriptor: transaction.oldManifest),
                Receipt.File(role: "old-current-workbook", descriptor: transaction.oldCurrentWorkbook),
                Receipt.File(role: "new-manifest", descriptor: transaction.newManifest),
                Receipt.File(role: "new-current-workbook", descriptor: transaction.newCurrentWorkbook),
            ],
            outputs: [
                Receipt.File(
                    role: action.contains("committed") ? "committed-current-workbook" : "restored-current-workbook",
                    descriptor: action.contains("committed")
                        ? transaction.newCurrentWorkbook
                        : transaction.oldCurrentWorkbook
                ),
            ],
            detail: detail
        )), to: url)
    }

    private static func claim(
        for transaction: ONTGenotypeWorkbookUpdateTransaction
    ) -> AttestationClaim {
        AttestationClaim(
            schemaVersion: transaction.schemaVersion,
            transactionID: transaction.transactionID,
            finalBundlePath: transaction.finalBundlePath,
            stagingBundlePath: transaction.stagingBundlePath,
            transactionRootPath: transaction.transactionRootPath,
            rotationTemporaryPath: transaction.rotationTemporaryPath,
            publicationMode: transaction.publicationMode,
            workflowName: transaction.workflowName,
            toolName: transaction.toolName,
            toolVersion: transaction.toolVersion,
            argv: transaction.argv,
            durableReplayArgv: transaction.durableReplayArgv,
            resolvedOptions: transaction.resolvedOptions,
            runtimeIdentity: transaction.runtimeIdentity,
            createdAt: Date(
                timeIntervalSince1970: floor(transaction.createdAt.timeIntervalSince1970)
            ),
            oldManifest: transaction.oldManifest,
            newManifest: transaction.newManifest,
            oldCurrentWorkbook: transaction.oldCurrentWorkbook,
            newCurrentWorkbook: transaction.newCurrentWorkbook,
            oldGenerationIdentity: transaction.oldGenerationIdentity,
            newGenerationIdentity: transaction.newGenerationIdentity,
            transactionRootIdentity: transaction.transactionRootIdentity,
            finalParentIdentity: transaction.finalParentIdentity
        )
    }

    private static func transaction(
        from record: AttestationRecord
    ) -> ONTGenotypeWorkbookUpdateTransaction {
        let claim = record.claim
        return ONTGenotypeWorkbookUpdateTransaction(
            schemaVersion: claim.schemaVersion,
            transactionID: claim.transactionID,
            finalBundlePath: claim.finalBundlePath,
            stagingBundlePath: claim.stagingBundlePath,
            transactionRootPath: claim.transactionRootPath,
            rotationTemporaryPath: claim.rotationTemporaryPath,
            publicationMode: claim.publicationMode,
            workflowName: claim.workflowName,
            toolName: claim.toolName,
            toolVersion: claim.toolVersion,
            argv: claim.argv,
            durableReplayArgv: claim.durableReplayArgv,
            resolvedOptions: claim.resolvedOptions,
            runtimeIdentity: claim.runtimeIdentity,
            createdAt: claim.createdAt,
            oldManifest: claim.oldManifest,
            newManifest: claim.newManifest,
            oldCurrentWorkbook: claim.oldCurrentWorkbook,
            newCurrentWorkbook: claim.newCurrentWorkbook,
            oldGenerationIdentity: claim.oldGenerationIdentity,
            newGenerationIdentity: claim.newGenerationIdentity,
            transactionRootIdentity: claim.transactionRootIdentity,
            finalParentIdentity: claim.finalParentIdentity,
            attestationID: record.attestationID,
            phase: .prepared
        )
    }

    private static func attestationURL(
        for transaction: ONTGenotypeWorkbookUpdateTransaction,
        attestationRootURL: URL?
    ) throws -> URL {
        guard let attestationID = transaction.attestationID,
              let parsed = UUID(uuidString: attestationID),
              parsed.uuidString == attestationID else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook transaction has no valid attestation identifier; no recovery action was taken."
            )
        }
        let root = try verifyAttestationRoot(attestationRootURL)
        return root.appendingPathComponent("\(attestationID).json")
    }

    private static func prepareAttestationRoot(_ supplied: URL?) throws -> URL {
        let root = try (supplied ?? defaultAttestationRootURL()).standardizedFileURL
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        return try verifyAttestationRoot(root)
    }

    private static func verifyAttestationRoot(_ supplied: URL?) throws -> URL {
        let root = try (supplied ?? defaultAttestationRootURL()).standardizedFileURL
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook attestation root is unavailable or unsafe; no recovery action was taken."
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_nlink >= 2,
              info.st_mode & 0o777 == 0o700 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook attestation root has unsafe ownership or permissions; no recovery action was taken."
            )
        }
        return root
    }

    private static func writeExclusiveAttestation(_ data: Data, to url: URL, root: URL) throws {
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(root.path, errno)
        }
        defer { Darwin.close(rootDescriptor) }
        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded {
                _ = temporaryName.withCString { Darwin.unlinkat(rootDescriptor, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    if errno == EINTR { continue }
                    throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
                }
                offset += written
            }
        }
        var info = stat()
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook attestation could not be made durable."
            )
        }
        let publishStatus = temporaryName.withCString { sourceName in
            url.lastPathComponent.withCString { destinationName in
                Darwin.renameatx_np(
                    rootDescriptor,
                    sourceName,
                    rootDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard publishStatus == 0, Darwin.fsync(rootDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook attestation could not be published atomically."
            )
        }
        succeeded = true
    }

    private static func requireAttestationRecord(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        attestationRootURL: URL?
    ) throws -> FileWitness {
        let url = try attestationURL(for: transaction, attestationRootURL: attestationRootURL)
        let (data, witness, info) = try readFileWithWitness(url)
        guard info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook attestation has unsafe ownership or permissions; no recovery action was taken."
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(AttestationRecord.self, from: data),
              record.schemaVersion == 1,
              record.attestationID == transaction.attestationID,
              UUID(uuidString: record.nonce)?.uuidString == record.nonce,
              record.claim == claim(for: transaction) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The detached workbook attestation does not authorize this transaction; no recovery action was taken."
            )
        }
        return witness
    }

    private static func loadRecoveryAuthority(
        for bundleURL: URL,
        attestationRootURL: URL?
    ) throws -> RecoveryAuthority {
        guard let authority = try loadRecoveryAuthorityIfPresent(
            for: bundleURL,
            attestationRootURL: attestationRootURL
        ) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "No authenticated workbook transaction exists for \(bundleURL.path)."
            )
        }
        return authority
    }

    private static func loadRecoveryAuthorityIfPresent(
        for bundleURL: URL,
        attestationRootURL: URL?
    ) throws -> RecoveryAuthority? {
        do {
            let markerURLs = try discoveredMarkerURLs(for: bundleURL)
            guard markerURLs.count <= 1 else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Multiple workbook transaction marker hints exist; no recovery action was taken."
                )
            }
            let markerURL = markerURLs.first
            var markerWitness: FileWitness?
            var markerData: Data?
            if let markerURL {
                let read = try readFileWithWitness(markerURL)
                markerData = read.0
                markerWitness = read.1
            }
            let candidates = try matchingAttestationCandidates(
                for: bundleURL,
                attestationRootURL: attestationRootURL
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let markerData,
               let transaction = try? decoder.decode(
                   ONTGenotypeWorkbookUpdateTransaction.self,
                   from: markerData
               ) {
                try validate(transaction, for: bundleURL)
                guard candidates.count == 1, let candidate = candidates.first,
                      candidate.transaction == transaction else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                        "The workbook transaction marker has \(candidates.count) matching detached attestations; no recovery action was taken."
                    )
                }
                return RecoveryAuthority(
                    transaction: transaction,
                    markerURL: markerURL,
                    markerWitness: markerWitness,
                    attestationWitness: candidate.witness
                )
            }
            guard !candidates.isEmpty || markerWitness != nil else { return nil }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "The workbook transaction has \(candidates.count) matching detached attestations; no recovery action was taken."
                )
            }
            return RecoveryAuthority(
                transaction: candidate.transaction,
                markerURL: markerURL,
                markerWitness: markerWitness,
                attestationWitness: candidate.witness
            )
        } catch let error as ONTGenotypeWorkbookUpdateRecoveryError {
            if case .ambiguousTransaction = error { throw error }
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook transaction could not be authenticated; no recovery action was taken. \(error.localizedDescription)"
            )
        } catch {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook transaction could not be authenticated; no recovery action was taken."
            )
        }
    }

    private static func matchingAttestationCandidates(
        for bundleURL: URL,
        attestationRootURL: URL?
    ) throws -> [(transaction: ONTGenotypeWorkbookUpdateTransaction, witness: FileWitness)] {
        let suppliedRoot = try (attestationRootURL ?? defaultAttestationRootURL()).standardizedFileURL
        var rootInfo = stat()
        guard Darwin.lstat(suppliedRoot.path, &rootInfo) == 0 else {
            if errno == ENOENT { return [] }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(suppliedRoot.path, errno)
        }
        let root = try verifyAttestationRoot(suppliedRoot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var matches: [(ONTGenotypeWorkbookUpdateTransaction, FileWitness)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path)
        where name.hasSuffix(".json") {
            let url = root.appendingPathComponent(name)
            guard let read = try? readFileWithWitness(url),
                  read.2.st_uid == geteuid(),
                  read.2.st_nlink == 1,
                  read.2.st_mode & 0o777 == 0o600,
                  let record = try? decoder.decode(AttestationRecord.self, from: read.0),
                  record.schemaVersion == 1,
                  UUID(uuidString: record.attestationID)?.uuidString == record.attestationID,
                  UUID(uuidString: record.nonce)?.uuidString == record.nonce else {
                continue
            }
            let reconstructed = transaction(from: record)
            guard NSString(string: reconstructed.finalBundlePath).standardizingPath
                    == bundleURL.standardizedFileURL.path,
                  record.claim == claim(for: reconstructed),
                  (try? validate(reconstructed, for: bundleURL)) != nil else {
                continue
            }
            matches.append((reconstructed, read.1))
        }
        return matches
    }

    private static func requireAuthorityUnchanged(
        _ authority: RecoveryAuthority,
        for bundleURL: URL,
        attestationRootURL: URL?
    ) throws {
        let currentMarker: FileWitness?
        if let markerURL = authority.markerURL {
            currentMarker = try readFileWithWitness(markerURL).1
        } else {
            guard try discoveredMarkerURLs(for: bundleURL).isEmpty else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "A workbook transaction marker appeared before mutation."
                )
            }
            currentMarker = nil
        }
        let attestation = try requireAttestationRecord(
            authority.transaction,
            attestationRootURL: attestationRootURL
        )
        guard currentMarker == authority.markerWitness,
              attestation == authority.attestationWitness else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook recovery authority changed before mutation; no recovery action was taken."
            )
        }
    }

    private static func removeMarkerAndAttestation(
        _ authority: RecoveryAuthority,
        for bundleURL: URL,
        attestationRootURL: URL?,
        cleanupFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws {
        if let markerWitness = authority.markerWitness {
            guard let markerURL = authority.markerURL else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "The authenticated marker path is unavailable."
                )
            }
            try unlinkExact(markerURL, expected: markerWitness)
            try cleanupFailureInjector?(
                "after-workbook-cleanup-marker-removal-hard-stop"
            )
        }
        let recordURL = try attestationURL(
            for: authority.transaction,
            attestationRootURL: attestationRootURL
        )
        try unlinkExact(recordURL, expected: authority.attestationWitness)
    }

    private static func recoverCleanupStateIfPresent(
        for bundleURL: URL,
        attestationRootURL: URL?,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws -> Bool {
        let states = try ONTGenotypeWorkbookCleanupStateStore.states(for: bundleURL)
        guard states.count <= 1 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Multiple workbook cleanup states claim \(bundleURL.path)."
            )
        }
        guard let (stateURL, state) = states.first else { return false }

        if let authority = try loadRecoveryAuthorityIfPresent(
            for: bundleURL,
            attestationRootURL: attestationRootURL
        ) {
            guard authority.transaction.transactionID == state.transactionID else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Workbook cleanup state and recovery authority claim different transactions."
                )
            }
            try requireAuthorityUnchanged(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL
            )
            try removeMarkerAndAttestation(
                authority,
                for: bundleURL,
                attestationRootURL: attestationRootURL,
                cleanupFailureInjector: failureInjector
            )
        }
        try ONTGenotypeWorkbookCleanupStateStore.removeQuarantineNoFollow(
            state: state,
            stateURL: stateURL,
            failureInjector: failureInjector
        )
        return true
    }

    private static func unlinkExact(_ url: URL, expected: FileWitness) throws {
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
        defer { Darwin.close(parentDescriptor) }
        var info = stat()
        let inspect = url.lastPathComponent.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard inspect == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == expected.device,
              info.st_ino == expected.inode,
              info.st_size == expected.size,
              url.lastPathComponent.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery authority file changed before cleanup."
            )
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
    }

    private static func readFileWithWitness(_ url: URL) throws -> (Data, FileWitness, stat) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
        }
        var data = Data()
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
            }
            let chunk = Data(buffer[0..<count])
            data.append(chunk)
            hasher.update(data: chunk)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              data.count == Int(after.st_size) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery authority file changed while it was read."
            )
        }
        return (
            data,
            FileWitness(
                device: before.st_dev,
                inode: before.st_ino,
                size: before.st_size,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            ),
            before
        )
    }

    private static func measureRegularFileNoFollow(_ url: URL) throws -> (size: Int64, sha256: String) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return (Int64(info.st_size), hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func readRegularFileNoFollow(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
            }
            data.append(buffer, count: count)
        }
    }

    private static func atomicWriteNoFollow(
        _ data: Data,
        to url: URL,
        renamePrimitive: ONTGenotypeAtomicRenamePrimitive? = nil,
        writeFailureInjector: (@Sendable (String) throws -> Void)? = nil,
        fileCreationObserver: (() -> Void)? = nil
    ) throws {
        let parent = url.deletingLastPathComponent()
        _ = renamePrimitive
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        fileCreationObserver?()
        // A failed write intentionally leaves a torn authority hint. The atomically
        // published detached attestation is the WAL used to rehydrate it.
        defer { Darwin.close(descriptor) }
        do {
            try writeFailureInjector?("after-marker-open-before-write")
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else {
                        if errno == EINTR { continue }
                        if count == 0 {
                            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, EIO)
                        }
                        throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
                    }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
            }
            var newInfo = stat()
            guard Darwin.fstat(descriptor, &newInfo) == 0,
                  newInfo.st_mode & S_IFMT == S_IFREG else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
            }
            try syncDirectory(parent)
        } catch {
            throw error
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
    }
}
