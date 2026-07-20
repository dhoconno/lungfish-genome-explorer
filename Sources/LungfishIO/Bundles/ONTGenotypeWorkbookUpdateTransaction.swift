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

public struct ONTGenotypeWorkbookUpdateTransaction: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: String
    public let finalBundlePath: String
    public let stagingBundlePath: String
    public let transactionRootPath: String
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
    public var phase: ONTGenotypeWorkbookUpdateTransactionPhase

    public init(
        schemaVersion: Int = 1,
        transactionID: String,
        finalBundlePath: String,
        stagingBundlePath: String,
        transactionRootPath: String,
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
        phase: ONTGenotypeWorkbookUpdateTransactionPhase = .prepared
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.finalBundlePath = finalBundlePath
        self.stagingBundlePath = stagingBundlePath
        self.transactionRootPath = transactionRootPath
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
        self.phase = phase
    }
}

public enum ONTGenotypeWorkbookUpdateRecoveryError: Error, LocalizedError, Sendable {
    case unsafeLock(String)
    case lockHeld(String)
    case systemFailure(String, Int32)
    case unsafeMarker(String)
    case invalidTransaction(String)
    case ambiguousTransaction(String)
    case currentWorkbookIntegrity(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeLock(let path): return "Workbook publication lock is unsafe: \(path)"
        case .lockHeld(let path): return "Workbook publication lock is already held: \(path)"
        case .systemFailure(let path, let code): return "Workbook transaction failed at \(path) (errno \(code))."
        case .unsafeMarker(let path): return "Workbook transaction marker is unsafe: \(path)"
        case .invalidTransaction(let message): return "Workbook transaction marker is invalid: \(message)"
        case .ambiguousTransaction(let message): return "Workbook transaction recovery is ambiguous: \(message)"
        case .currentWorkbookIntegrity(let message): return "The current workbook failed integrity validation: \(message)"
        }
    }
}

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
        blocking: Bool = false
    ) throws -> ONTGenotypeBundlePublicationLock {
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
        defer { Darwin.close(parentDescriptor) }
        let lockURL = lockURL(for: bundleURL)
        let descriptor = lockURL.lastPathComponent.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeLock(lockURL.path) }
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
        bundleURL.standardizedFileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(bundleURL.lastPathComponent).workbook-update-transaction.json"
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

    public static func write(_ transaction: ONTGenotypeWorkbookUpdateTransaction, for bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try atomicWriteNoFollow(try encoder.encode(transaction), to: markerURL(for: bundleURL))
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
        for bundleURL: URL
    ) throws {
        try validate(transaction, for: bundleURL)
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        guard generationState(at: final, transaction: transaction) == .committedNew,
              generationState(at: staging, transaction: transaction) == .old else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Cannot finalize a workbook transaction whose committed and prior generations do not match the journal."
            )
        }
        try removeProvenTransactionRoot(transaction)
        try removeMarker(for: bundleURL)
    }

    public static func recoverIfNeededAssumingLock(for bundleURL: URL) throws {
        let marker = markerURL(for: bundleURL)
        var markerInfo = stat()
        guard Darwin.lstat(marker.path, &markerInfo) == 0 else {
            if errno == ENOENT { return }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(marker.path, errno)
        }
        guard markerInfo.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(marker.path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transaction = try decoder.decode(
            ONTGenotypeWorkbookUpdateTransaction.self,
            from: readRegularFileNoFollow(marker)
        )
        try validate(transaction, for: bundleURL)
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        let finalState = generationState(at: final, transaction: transaction)
        let stagingState = generationState(at: staging, transaction: transaction)

        if finalState == .old, stagingState == .preparedNew {
            try removeProvenTransactionRoot(transaction)
            try writeReceipt(transaction, action: "discarded-unpublished-staging", detail: "Final generation remained unchanged.")
            try removeMarker(for: bundleURL)
            return
        }
        if finalState == .preparedNew, stagingState == .old {
            try exchange(final, staging)
            guard generationState(at: final, transaction: transaction) == .old else {
                throw try ambiguous(transaction, detail: "Rollback exchange did not restore the prior generation.")
            }
            try removeProvenTransactionRoot(transaction)
            try writeReceipt(transaction, action: "restored-prior-generation", detail: "Recovered an interrupted pre-manifest workbook publication.")
            try removeMarker(for: bundleURL)
            return
        }
        if finalState == .committedNew, stagingState == .old {
            try removeProvenTransactionRoot(transaction)
            try writeReceipt(transaction, action: "finished-committed-cleanup", detail: "The new manifest and workbook were already durable.")
            try removeMarker(for: bundleURL)
            return
        }
        if finalState == .committedNew, stagingState == .missing {
            try writeReceipt(transaction, action: "finished-committed-marker-cleanup", detail: "The prior generation had already been retired.")
            try removeMarker(for: bundleURL)
            return
        }
        if finalState == .old, !FileManager.default.fileExists(atPath: staging.path) {
            try removeProvenTransactionRoot(transaction)
            try writeReceipt(transaction, action: "finished-rollback-cleanup", detail: "The prior generation was already restored.")
            try removeMarker(for: bundleURL)
            return
        }
        throw try ambiguous(
            transaction,
            detail: "final=\(finalState.rawValue), staging=\(stagingState.rawValue); both generations were preserved"
        )
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

    private enum GenerationState: String {
        case old
        case preparedNew
        case committedNew
        case missing
        case ambiguous
    }

    private static func generationState(
        at bundleURL: URL,
        transaction: ONTGenotypeWorkbookUpdateTransaction
    ) -> GenerationState {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return .missing }
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
        if oldManifest && oldWorkbook { return .old }
        if oldManifest && newWorkbook { return .preparedNew }
        if newManifest && newWorkbook { return .committedNew }
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
        let final = bundleURL.standardizedFileURL
        guard transaction.schemaVersion == 1,
              URL(fileURLWithPath: transaction.finalBundlePath).standardizedFileURL == final,
              transaction.oldManifest.path == ONTGenotypeResultBundleManifest.filename,
              transaction.newManifest.path == ONTGenotypeResultBundleManifest.filename,
              transaction.oldCurrentWorkbook.path == transaction.newCurrentWorkbook.path else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(markerURL(for: bundleURL).path)
        }
        let parent = final.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true).standardizedFileURL
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true).standardizedFileURL
        guard root.deletingLastPathComponent() == parent,
              staging.deletingLastPathComponent() == root,
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

    private static func ambiguous(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        detail: String
    ) throws -> ONTGenotypeWorkbookUpdateRecoveryError {
        var updated = transaction
        updated.phase = .ambiguous
        try write(updated, for: URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true))
        try writeReceipt(updated, action: "ambiguous-preserved", detail: detail)
        return .ambiguousTransaction(detail)
    }

    private static func removeProvenTransactionRoot(_ transaction: ONTGenotypeWorkbookUpdateTransaction) throws {
        let root = URL(fileURLWithPath: transaction.transactionRootPath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingBundlePath, isDirectory: true)
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        guard staging.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              staging.lastPathComponent == final.lastPathComponent,
              root.lastPathComponent.hasPrefix(".\(final.lastPathComponent).workbook-update-"),
              root.lastPathComponent.hasSuffix(".staging") else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction("unsafe transaction cleanup root")
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try removeTreeNoFollow(root)
            try syncDirectory(root.deletingLastPathComponent())
        }
    }

    private static func removeTreeNoFollow(_ root: URL) throws {
        let parent = root.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
        defer { Darwin.close(parentDescriptor) }
        let rootDescriptor = root.lastPathComponent.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction("cleanup root is not a real directory")
        }
        var rootInfo = stat()
        guard Darwin.fstat(rootDescriptor, &rootInfo) == 0 else {
            Darwin.close(rootDescriptor)
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(root.path, errno)
        }
        do {
            try removeDirectoryContentsNoFollow(rootDescriptor, displayURL: root)
            var pathInfo = stat()
            let inspectStatus = root.lastPathComponent.withCString {
                Darwin.fstatat(parentDescriptor, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard inspectStatus == 0,
                  pathInfo.st_mode & S_IFMT == S_IFDIR,
                  pathInfo.st_dev == rootInfo.st_dev,
                  pathInfo.st_ino == rootInfo.st_ino else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction("cleanup root changed during removal")
            }
            let removeStatus = root.lastPathComponent.withCString {
                Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            guard removeStatus == 0 else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(root.path, errno)
            }
            Darwin.close(rootDescriptor)
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    private static func removeDirectoryContentsNoFollow(
        _ directoryDescriptor: Int32,
        displayURL: URL
    ) throws {
        let enumerationDescriptor = Darwin.dup(directoryDescriptor)
        guard enumerationDescriptor >= 0, let stream = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(displayURL.path, errno)
        }
        defer { Darwin.closedir(stream) }
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let childURL = displayURL.appendingPathComponent(name)
            var childInfo = stat()
            let inspectStatus = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &childInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard inspectStatus == 0 else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(childURL.path, errno)
            }
            if childInfo.st_mode & S_IFMT == S_IFDIR {
                let childDescriptor = name.withCString {
                    Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard childDescriptor >= 0 else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(childURL.path, errno)
                }
                do {
                    try removeDirectoryContentsNoFollow(childDescriptor, displayURL: childURL)
                    var currentInfo = stat()
                    let currentStatus = name.withCString {
                        Darwin.fstatat(directoryDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW)
                    }
                    guard currentStatus == 0,
                          currentInfo.st_mode & S_IFMT == S_IFDIR,
                          currentInfo.st_dev == childInfo.st_dev,
                          currentInfo.st_ino == childInfo.st_ino,
                          name.withCString({ Darwin.unlinkat(directoryDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
                        throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                            "cleanup directory changed during removal: \(childURL.path)"
                        )
                    }
                    Darwin.close(childDescriptor)
                } catch {
                    Darwin.close(childDescriptor)
                    throw error
                }
            } else {
                guard name.withCString({ Darwin.unlinkat(directoryDescriptor, $0, 0) }) == 0 else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(childURL.path, errno)
                }
            }
        }
    }

    private static func exchange(_ lhs: URL, _ rhs: URL) throws {
        guard Darwin.renameatx_np(AT_FDCWD, lhs.path, AT_FDCWD, rhs.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(rhs.path, errno)
        }
        try syncDirectory(rhs.deletingLastPathComponent())
    }

    private static func writeReceipt(
        _ transaction: ONTGenotypeWorkbookUpdateTransaction,
        action: String,
        detail: String
    ) throws {
        let final = URL(fileURLWithPath: transaction.finalBundlePath, isDirectory: true)
        let url = final.deletingLastPathComponent().appendingPathComponent(
            ".\(final.lastPathComponent).workbook-update-recovery-\(transaction.transactionID).json"
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

    private static func atomicWriteNoFollow(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(temporary.path, errno)
        }
        var descriptorIsOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else {
                        if errno == EINTR { continue }
                        if count == 0 {
                            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(temporary.path, EIO)
                        }
                        throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(temporary.path, errno)
                    }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(temporary.path, errno)
            }
            Darwin.close(descriptor)
            descriptorIsOpen = false
            var existing = stat()
            if Darwin.lstat(url.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG,
                      Darwin.renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
                }
                var swappedOut = stat()
                guard Darwin.lstat(temporary.path, &swappedOut) == 0,
                      swappedOut.st_mode & S_IFMT == S_IFREG,
                      swappedOut.st_dev == existing.st_dev,
                      swappedOut.st_ino == existing.st_ino,
                      Darwin.unlink(temporary.path) == 0 else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
                }
            } else {
                guard errno == ENOENT,
                      Darwin.renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
                }
            }
            try syncDirectory(parent)
        } catch {
            if descriptorIsOpen { Darwin.close(descriptor) }
            var temporaryInfo = stat()
            if Darwin.lstat(temporary.path, &temporaryInfo) == 0,
               temporaryInfo.st_mode & S_IFMT == S_IFREG {
                _ = Darwin.unlink(temporary.path)
            }
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
