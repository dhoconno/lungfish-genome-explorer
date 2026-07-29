import CryptoKit
import Darwin
import Foundation

struct ONTGenotypeWorkbookRetirementFileWitness: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let sha256: String
}

struct ONTGenotypeWorkbookCleanupOperations: Sendable {
    typealias RenameExclusive = @Sendable (
        Int32,
        UnsafePointer<CChar>,
        Int32,
        UnsafePointer<CChar>,
        UInt32,
        PortableExclusiveRename.RegularSourceWitness?
    ) -> PortableExclusiveRename.Outcome

    var renameExclusive: RenameExclusive
    var checkpoint: @Sendable (String) throws -> Void

    init(
        renameExclusive: @escaping RenameExclusive = {
            PortableExclusiveRename.renameatxNPReporting(
                $0,
                $1,
                $2,
                $3,
                $4,
                sourceWitness: $5
            )
        },
        checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }
    ) {
        self.renameExclusive = renameExclusive
        self.checkpoint = checkpoint
    }

    static let darwin = ONTGenotypeWorkbookCleanupOperations()
}

enum ONTGenotypeWorkbookCleanupRebaseClassifier {
    enum Decision: Equatable {
        case exact(device: dev_t, inode: ino_t)
        case rebased(device: dev_t, inode: ino_t)
        case reject
    }

    static func classify(
        before: stat,
        postDescriptor: stat,
        postPath: stat,
        mechanism: PortableExclusiveRename.Mechanism,
        originalNameIsAbsent: Bool
    ) -> Decision {
        guard originalNameIsAbsent,
              sameKernelIdentity(postDescriptor, postPath) else {
            return .reject
        }
        if sameKernelIdentity(before, postDescriptor) {
            return .exact(
                device: postDescriptor.st_dev,
                inode: postDescriptor.st_ino
            )
        }
        guard mechanism == .reservationFallback,
              before.st_mode & S_IFMT == S_IFREG,
              postDescriptor.st_mode & S_IFMT == S_IFREG,
              before.st_size == 0,
              postDescriptor.st_size == 0,
              stableMetadataMatches(before, postDescriptor) else {
            return .reject
        }
        return .rebased(
            device: postDescriptor.st_dev,
            inode: postDescriptor.st_ino
        )
    }

    static func sameKernelIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }

    static func identityAndStableMetadataMatch(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        sameKernelIdentity(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mode & mode_t(0o7777) == rhs.st_mode & mode_t(0o7777)
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func stableMetadataMatches(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_size == rhs.st_size
            && lhs.st_mode & mode_t(0o7777) == rhs.st_mode & mode_t(0o7777)
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

// Retirement is performed under the bundle publication lock; that lock is the
// cooperative boundary for bundle-parent entries. Detached attestations also
// live beneath an owner-only 0700 authority root. Cooperating Lungfish
// processes must not mutate retirement tombstones.
// macOS has no unlink-by-witness primitive: unlinkat(2) is name-based and
// cannot condition deletion on a previously witnessed inode. A same-user
// process that ignores the applicable cooperative boundary can therefore race
// even the final witness/unlinkat pair. We narrow
// that unavoidable kernel gap with a second randomized exclusive rename,
// preserve anything substituted at the injectable boundary, re-witness the
// final name, and expose no callback between that final witness and unlink.
enum ONTGenotypeWorkbookRetirement {
    static func fileWitness(
        at url: URL
    ) throws -> (Data, ONTGenotypeWorkbookRetirementFileWitness, stat) {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                url.path,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
        }
        var data = Data()
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                    url.path,
                    errno
                )
            }
            data.append(buffer, count: count)
            digest.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery file changed while it was read."
            )
        }
        return (
            data,
            ONTGenotypeWorkbookRetirementFileWitness(
                device: after.st_dev,
                inode: after.st_ino,
                size: after.st_size,
                sha256: digest.finalize().map {
                    String(format: "%02x", $0)
                }.joined()
            ),
            after
        )
    }

    static func retireRegularFile(
        at url: URL,
        expected: ONTGenotypeWorkbookRetirementFileWitness,
        checkpoint: String,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                parent.path,
                errno
            )
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
              info.st_size == expected.size else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery authority file changed before retirement."
            )
        }
        try failureInjector?("\(checkpoint):\(url.path)")
        let tombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let detached = url.lastPathComponent.withCString { sourceName in
            tombstone.withCString { destinationName in
                PortableExclusiveRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery authority file changed before it could be detached."
            )
        }
        let tombstoneURL = parent.appendingPathComponent(tombstone)
        let detachedWitness = try? fileWitness(at: tombstoneURL).1
        guard detachedWitness == expected else {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: url.lastPathComponent,
                displayedAt: tombstoneURL
            )
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A substituted workbook recovery file was detached and preserved."
            )
        }
        do {
            try failureInjector?(
                "after-workbook-retirement-witness:\(url.path)"
            )
        } catch {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: url.lastPathComponent,
                displayedAt: tombstoneURL
            )
            throw error
        }

        let finalTombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let redetached = tombstone.withCString { sourceName in
            finalTombstone.withCString { destinationName in
                PortableExclusiveRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard redetached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "A workbook recovery authority file changed after its retirement witness; the entry was preserved."
                )
        }
        let finalTombstoneURL = parent.appendingPathComponent(finalTombstone)
        let finalWitness = try? fileWitness(at: finalTombstoneURL).1
        guard finalWitness == expected else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "A substituted workbook recovery file was preserved at \(finalTombstoneURL.path)."
                )
        }
        let removed = finalTombstone.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        guard removed == 0, Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                finalTombstoneURL.path,
                errno
            )
        }
    }

    static func retireDirectory(
        named name: String,
        beneath parentDescriptor: Int32,
        parentURL: URL,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        checkpoint: String,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        var info = stat()
        let inspect = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard inspect == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(info.st_dev)) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook cleanup quarantine changed before retirement."
            )
        }
        let displayedURL = parentURL.appendingPathComponent(
            name,
            isDirectory: true
        )
        try failureInjector?("\(checkpoint):\(displayedURL.path)")
        let tombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let detached = name.withCString { sourceName in
            tombstone.withCString { destinationName in
                PortableExclusiveRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook cleanup quarantine changed before it could be detached."
            )
        }
        var detachedInfo = stat()
        let detachedStatus = tombstone.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &detachedInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard detachedStatus == 0,
              detachedInfo.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(detachedInfo.st_dev))
                == expected.device,
              UInt64(detachedInfo.st_ino) == expected.inode else {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: name,
                displayedAt: parentURL.appendingPathComponent(tombstone)
            )
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A substituted workbook cleanup quarantine was detached and preserved."
            )
        }
        do {
            try failureInjector?(
                "after-workbook-retirement-witness:\(displayedURL.path)"
            )
        } catch {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: name,
                displayedAt: parentURL.appendingPathComponent(tombstone)
            )
            throw error
        }

        let finalTombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let redetached = tombstone.withCString { sourceName in
            finalTombstone.withCString { destinationName in
                PortableExclusiveRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard redetached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "The workbook cleanup quarantine changed after its retirement witness; the entry was preserved."
                )
        }
        let finalTombstoneURL = parentURL.appendingPathComponent(
            finalTombstone,
            isDirectory: true
        )
        var finalInfo = stat()
        let finalStatus = finalTombstone.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &finalInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard finalStatus == 0,
              finalInfo.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(finalInfo.st_dev))
                == expected.device,
              UInt64(finalInfo.st_ino) == expected.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "A substituted workbook cleanup quarantine was preserved at \(finalTombstoneURL.path)."
                )
        }
        let removed = finalTombstone.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard removed == 0, Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                finalTombstoneURL.path,
                errno
            )
        }
    }

    private static func restoreDetachedEntry(
        parentDescriptor: Int32,
        tombstone: String,
        original: String,
        displayedAt: URL
    ) throws {
        let restored = tombstone.withCString { sourceName in
            original.withCString { destinationName in
                PortableExclusiveRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard restored == 0, Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A substituted retirement target was preserved at \(displayedAt.path)."
            )
        }
    }
}

public enum ONTGenotypeWorkbookCleanupDecision: String, Codable, Sendable {
    case committed
    case preparedDiscard = "prepared-discard"
    case rollback
    case manualSaveWinner = "manual-save-winner"
}

public struct ONTGenotypeWorkbookCleanupState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: String
    public let finalBundlePath: String
    public let sourceRootPath: String
    public let quarantinePath: String
    public let parentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let sourceIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let quarantineIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let survivorIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let survivorManifest: ONTGenotypeWorkbookUpdateFileDescriptor
    public let survivorCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
    public let transaction: ONTGenotypeWorkbookUpdateTransaction
    public let terminalReceiptAction: String
    public let terminalReceiptDetail: String
    public let decision: ONTGenotypeWorkbookCleanupDecision
    public let retryState: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = 3,
        transactionID: String,
        finalBundlePath: String,
        sourceRootPath: String,
        quarantinePath: String,
        parentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        sourceIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        quarantineIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        survivorIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        survivorManifest: ONTGenotypeWorkbookUpdateFileDescriptor,
        survivorCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor,
        transaction: ONTGenotypeWorkbookUpdateTransaction,
        terminalReceiptAction: String,
        terminalReceiptDetail: String,
        decision: ONTGenotypeWorkbookCleanupDecision,
        retryState: String = "cleanup-pending",
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.finalBundlePath = finalBundlePath
        self.sourceRootPath = sourceRootPath
        self.quarantinePath = quarantinePath
        self.parentIdentity = parentIdentity
        self.sourceIdentity = sourceIdentity
        self.quarantineIdentity = quarantineIdentity
        self.survivorIdentity = survivorIdentity
        self.survivorManifest = survivorManifest
        self.survivorCurrentWorkbook = survivorCurrentWorkbook
        self.transaction = transaction
        self.terminalReceiptAction = terminalReceiptAction
        self.terminalReceiptDetail = terminalReceiptDetail
        self.decision = decision
        self.retryState = retryState
        self.createdAt = createdAt
    }
}

struct ONTGenotypeWorkbookCleanupWarning: Codable, Sendable {
    let schemaVersion: Int
    let transactionID: String
    let finalBundlePath: String
    let quarantinePath: String
    let statePath: String
    let decision: ONTGenotypeWorkbookCleanupDecision
    let retryState: String
    let reason: String
    let recordedAt: Date
}

enum ONTGenotypeWorkbookCleanupStateStore {
    struct SurvivorAuthority {
        let identity: ONTGenotypeWorkbookUpdateDirectoryIdentity
        let manifest: ONTGenotypeWorkbookUpdateFileDescriptor
        let currentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func quarantineURL(
        transactionID: String,
        parent: URL
    ) -> URL {
        parent.appendingPathComponent(
            ".lungfish-workbook-cleanup-pending-\(transactionID)",
            isDirectory: true
        )
    }

    static func stateURL(
        transactionID: String,
        bundleURL: URL
    ) -> URL {
        bundleURL.deletingLastPathComponent().appendingPathComponent(
            ".\(bundleURL.lastPathComponent).workbook-cleanup-state-\(transactionID).json"
        )
    }

    static func terminalReceiptDisposition(
        for decision: ONTGenotypeWorkbookCleanupDecision
    ) -> (action: String, detail: String) {
        switch decision {
        case .committed:
            return (
                "finished-committed-cleanup",
                "The committed workbook generation is durable and the retired generation was removed."
            )
        case .preparedDiscard:
            return (
                "finished-prepared-discard-cleanup",
                "The unpublished prepared generation was durably removed."
            )
        case .rollback:
            return (
                "finished-rollback-cleanup",
                "The prior workbook generation was restored and the retired generation was removed."
            )
        case .manualSaveWinner:
            return (
                "finished-manual-save-winner-cleanup",
                "The manually edited workbook generation was preserved and the generated revision was removed."
            )
        }
    }

    static func transactionSemanticsMatch(
        _ lhs: ONTGenotypeWorkbookUpdateTransaction,
        _ rhs: ONTGenotypeWorkbookUpdateTransaction
    ) -> Bool {
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else {
            return false
        }
        return lhsData == rhsData
    }

    static func states(for bundleURL: URL) throws -> [(URL, ONTGenotypeWorkbookCleanupState)] {
        let requested = URL(
            fileURLWithPath: lexicalPath(bundleURL),
            isDirectory: true
        )
        let parent = requested.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                parent.path,
                errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        let actualBundleName = try identityBoundBundleNameIfPresent(
            requested,
            parentDescriptor: parentDescriptor
        )
        let requestedPrefix =
            ".\(requested.lastPathComponent).workbook-cleanup-state-"
        let names = try directoryEntryNames(
            descriptor: parentDescriptor,
            displayedAt: parent
        ).filter { name in
            guard name.hasSuffix(".json") else { return false }
            if let actualBundleName {
                return name.hasPrefix(
                    ".\(actualBundleName).workbook-cleanup-state-"
                )
            }
            return String(name.prefix(requestedPrefix.count))
                .caseInsensitiveCompare(requestedPrefix) == .orderedSame
        }.sorted()
        return try names.map { name in
            guard DurableAtomicFileStore.isSinglePathComponent(name) else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                    "unsafe workbook cleanup-state name: \(name)"
                )
            }
            let url = parent.appendingPathComponent(name)
            let read = try readRelativeRegularFile(
                name,
                beneath: parentDescriptor,
                displayedAt: parent,
                collectDataLimit: 16 * 1_024 * 1_024
            )
            guard let data = read.data else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                    "Workbook cleanup state could not be read: \(url.path)"
                )
            }
            let state = try decoder.decode(ONTGenotypeWorkbookCleanupState.self, from: data)
            let stateBundle = URL(
                fileURLWithPath: lexicalPath(
                    URL(fileURLWithPath: state.finalBundlePath)
                ),
                isDirectory: true
            )
            let bundle: URL
            if let actualBundleName {
                bundle = parent.appendingPathComponent(
                    actualBundleName,
                    isDirectory: true
                )
            } else {
                guard stateBundle.deletingLastPathComponent().path == parent.path,
                      stateBundle.lastPathComponent.caseInsensitiveCompare(
                          requested.lastPathComponent
                      ) == .orderedSame else {
                    throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                        "Markerless workbook cleanup state does not identify the requested bundle."
                    )
                }
                bundle = stateBundle
            }
            try validate(state, at: url, for: bundle)
            return (url, state)
        }
    }

    static func write(
        _ state: ONTGenotypeWorkbookCleanupState,
        at stateURL: URL
    ) throws {
        try validate(state, at: stateURL, for: URL(
            fileURLWithPath: state.finalBundlePath,
            isDirectory: true
        ))
        if fileIdentityIfPresent(stateURL) != nil {
            let existing = try decoder.decode(
                ONTGenotypeWorkbookCleanupState.self,
                from: readRegularFileNoFollow(stateURL)
            )
            guard existing == state else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                    "Workbook cleanup state changed: \(stateURL.path)"
                )
            }
            return
        }
        let store = DurableAtomicFileStore()
        try store.create(
            try encoder.encode(state),
            named: stateURL.lastPathComponent,
            in: stateURL.deletingLastPathComponent()
        )
    }

    static func removeState(
        at stateURL: URL,
        expectedState: ONTGenotypeWorkbookCleanupState,
        failureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws {
        let read: (
            Data,
            ONTGenotypeWorkbookRetirementFileWitness,
            stat
        )
        do {
            read = try ONTGenotypeWorkbookRetirement.fileWitness(at: stateURL)
        } catch let error as ONTGenotypeWorkbookUpdateRecoveryError {
            if case let .systemFailure(_, code) = error, code == ENOENT {
                return
            }
            throw error
        }
        guard try decoder.decode(
            ONTGenotypeWorkbookCleanupState.self,
            from: read.0
        ) == expectedState else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Workbook cleanup state was substituted before retirement: \(stateURL.path)"
            )
        }
        try ONTGenotypeWorkbookRetirement.retireRegularFile(
            at: stateURL,
            expected: read.1,
            checkpoint: "before-workbook-cleanup-state-detach",
            failureInjector: failureInjector
        )
    }

    @discardableResult
    static func recordWarning(
        state: ONTGenotypeWorkbookCleanupState,
        stateURL: URL,
        reason: String
    ) throws -> URL {
        let bundle = URL(fileURLWithPath: state.finalBundlePath, isDirectory: true)
        let name =
            ".\(bundle.lastPathComponent).workbook-cleanup-warning-"
            + "\(state.transactionID)-\(UUID().uuidString.lowercased()).json"
        let warningURL = bundle.deletingLastPathComponent().appendingPathComponent(name)
        let warning = ONTGenotypeWorkbookCleanupWarning(
            schemaVersion: 1,
            transactionID: state.transactionID,
            finalBundlePath: state.finalBundlePath,
            quarantinePath: state.quarantinePath,
            statePath: stateURL.path,
            decision: state.decision,
            retryState: state.retryState,
            reason: reason,
            recordedAt: Date()
        )
        try DurableAtomicFileStore().create(
            try encoder.encode(warning),
            named: name,
            in: warningURL.deletingLastPathComponent()
        )
        return warningURL
    }

    static func removeQuarantineNoFollow(
        state: ONTGenotypeWorkbookCleanupState,
        stateURL: URL,
        failureInjector: (@Sendable (String) throws -> Void)?,
        cleanupOperations: ONTGenotypeWorkbookCleanupOperations = .darwin,
        completion: () throws -> Void
    ) throws {
        do {
            try validateSurvivor(state)
        } catch {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "The surviving workbook generation is unavailable or changed: "
                    + error.localizedDescription,
                failureInjector: failureInjector
            )
        }
        let parent = URL(
            fileURLWithPath: state.parentIdentity.path,
            isDirectory: true
        )
        let quarantine = URL(
            fileURLWithPath: state.quarantinePath,
            isDirectory: true
        )
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
        defer { Darwin.close(parentDescriptor) }
        try requireIdentity(
            descriptor: parentDescriptor,
            expected: state.parentIdentity,
            path: parent.path
        )

        var entryInfo = stat()
        let inspect = quarantine.lastPathComponent.withCString {
            Darwin.fstatat(parentDescriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard inspect == 0 else {
            if errno == ENOENT {
                try completion()
                try removeState(
                    at: stateURL,
                    expectedState: state,
                    failureInjector: failureInjector
                )
                return
            }
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Could not inspect cleanup quarantine (errno \(errno)).",
                failureInjector: failureInjector
            )
        }
        guard matches(entryInfo, state.quarantineIdentity) else {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Cleanup quarantine identity changed before traversal.",
                failureInjector: failureInjector
            )
        }
        let descriptor = quarantine.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Could not open cleanup quarantine without following links (errno \(errno)).",
                failureInjector: failureInjector
            )
        }
        defer { Darwin.close(descriptor) }
        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              matches(openedInfo, state.quarantineIdentity) else {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Opened cleanup quarantine identity does not match durable state.",
                failureInjector: failureInjector
            )
        }

        do {
            try failureInjector?("during-workbook-cleanup-traversal")
            var currentInfo = stat()
            let currentStatus = quarantine.lastPathComponent.withCString {
                Darwin.fstatat(parentDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard currentStatus == 0,
                  matches(currentInfo, state.quarantineIdentity) else {
                throw CleanupTraversalError(
                    detail: "Cleanup quarantine moved or was substituted before traversal."
                )
            }
            try removeContentsNoFollow(
                descriptor: descriptor,
                displayedAt: quarantine,
                failureInjector: failureInjector,
                cleanupOperations: cleanupOperations
            )
            try ONTGenotypeWorkbookRetirement.retireDirectory(
                named: quarantine.lastPathComponent,
                beneath: parentDescriptor,
                parentURL: parent,
                expected: state.quarantineIdentity,
                checkpoint: "before-workbook-cleanup-quarantine-detach",
                failureInjector: failureInjector
            )
            try completion()
            try removeState(
                at: stateURL,
                expectedState: state,
                failureInjector: failureInjector
            )
        } catch let error as ONTGenotypeWorkbookUpdateRecoveryError {
            throw error
        } catch {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: error.localizedDescription,
                failureInjector: failureInjector
            )
        }
    }

    static func captureSurvivorAuthority(
        bundleURL: URL,
        expectedIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        expectedManifest: ONTGenotypeWorkbookUpdateFileDescriptor,
        expectedCurrentWorkbookPath: String
    ) throws -> SurvivorAuthority {
        let bundle = bundleURL.standardizedFileURL
        let expected = ONTGenotypeWorkbookUpdateDirectoryIdentity(
            path: bundle.path,
            device: expectedIdentity.device,
            inode: expectedIdentity.inode
        )
        let descriptor = Darwin.open(
            bundle.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                bundle.path,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        try requireIdentity(
            descriptor: descriptor,
            expected: expected,
            path: bundle.path
        )

        let manifestRead = try readRelativeRegularFile(
            expectedManifest.path,
            beneath: descriptor,
            displayedAt: bundle,
            collectDataLimit: 16 * 1_024 * 1_024
        )
        guard manifestRead.descriptor == expectedManifest,
              let manifestData = manifestRead.data else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The surviving generation manifest does not match publication authority."
            )
        }
        let manifest: ONTGenotypeResultBundleManifest
        do {
            manifest = try JSONDecoder().decode(
                ONTGenotypeResultBundleManifest.self,
                from: manifestData
            )
        } catch {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The surviving generation manifest is not valid JSON: \(error.localizedDescription)"
            )
        }
        let currentWorkbookPath =
            manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath
        guard currentWorkbookPath == expectedCurrentWorkbookPath else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The surviving generation manifest names an unexpected current workbook."
            )
        }
        let workbookRead = try readRelativeRegularFile(
            currentWorkbookPath,
            beneath: descriptor,
            displayedAt: bundle,
            collectDataLimit: nil
        )
        return SurvivorAuthority(
            identity: expected,
            manifest: manifestRead.descriptor,
            currentWorkbook: workbookRead.descriptor
        )
    }

    private struct CleanupTraversalError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static func throwWarning(
        state: ONTGenotypeWorkbookCleanupState,
        stateURL: URL,
        reason: String,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws -> Never {
        let warningURL: URL
        do {
            try failureInjector?("before-workbook-cleanup-warning-write")
            warningURL = try recordWarning(
                state: state,
                stateURL: stateURL,
                reason: reason
            )
        } catch {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .cleanupPendingWarningPersistenceFailure(
                    quarantinePath: state.quarantinePath,
                    retryState: state.retryState,
                    reason: reason,
                    warningFailure: error.localizedDescription
                )
        }
        throw ONTGenotypeWorkbookUpdateRecoveryError.cleanupPendingWarning(
            quarantinePath: state.quarantinePath,
            retryState: state.retryState,
            warningPath: warningURL.path,
            reason: reason
        )
    }

    private static func validate(
        _ state: ONTGenotypeWorkbookCleanupState,
        at stateURL: URL,
        for bundleURL: URL
    ) throws {
        let bundle = URL(
            fileURLWithPath: lexicalPath(bundleURL),
            isDirectory: true
        )
        let parent = bundle.deletingLastPathComponent()
        let expectedStateURL = self.stateURL(
            transactionID: state.transactionID,
            bundleURL: bundle
        )
        let expectedQuarantine = quarantineURL(
            transactionID: state.transactionID,
            parent: parent
        )
        do {
            try ONTGenotypeWorkbookUpdateRecovery.validate(
                state.transaction,
                for: bundle
            )
        } catch {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Invalid workbook cleanup state transaction: \(stateURL.path)"
            )
        }
        let expectedDisposition = terminalReceiptDisposition(
            for: state.decision
        )
        let transactionSurvivorIdentity:
            ONTGenotypeWorkbookUpdateDirectoryIdentity
        let expectedSurvivorManifest:
            ONTGenotypeWorkbookUpdateFileDescriptor
        let expectedSurvivorCurrentWorkbook:
            ONTGenotypeWorkbookUpdateFileDescriptor
        switch state.decision {
        case .committed:
            transactionSurvivorIdentity =
                state.transaction.newGenerationIdentity
            expectedSurvivorManifest = state.transaction.newManifest
            expectedSurvivorCurrentWorkbook =
                state.transaction.newCurrentWorkbook
        case .preparedDiscard, .rollback, .manualSaveWinner:
            transactionSurvivorIdentity =
                state.transaction.oldGenerationIdentity
            expectedSurvivorManifest = state.transaction.oldManifest
            expectedSurvivorCurrentWorkbook =
                state.transaction.oldCurrentWorkbook
        }
        let expectedSurvivorIdentity =
            ONTGenotypeWorkbookUpdateDirectoryIdentity(
                path: state.finalBundlePath,
                device: transactionSurvivorIdentity.device,
                inode: transactionSurvivorIdentity.inode
            )
        let expectedQuarantineIdentity =
            ONTGenotypeWorkbookUpdateDirectoryIdentity(
                path: state.quarantinePath,
                device: state.transaction.transactionRootIdentity.device,
                inode: state.transaction.transactionRootIdentity.inode
            )
        guard state.schemaVersion == 3,
              state.retryState == "cleanup-pending",
              DurableAtomicFileStore.isSinglePathComponent(state.transactionID),
              lexicalPath(URL(fileURLWithPath: state.finalBundlePath)) == bundle.path,
              lexicalPath(stateURL) == lexicalPath(expectedStateURL),
              lexicalPath(URL(fileURLWithPath: state.quarantinePath))
                == lexicalPath(expectedQuarantine),
              lexicalPath(
                  URL(fileURLWithPath: state.sourceRootPath)
                      .deletingLastPathComponent()
              ) == parent.path,
              state.sourceRootPath == state.transaction.transactionRootPath,
              state.parentIdentity == state.transaction.finalParentIdentity,
              state.sourceIdentity
                == state.transaction.transactionRootIdentity,
              state.quarantineIdentity == expectedQuarantineIdentity,
              state.survivorIdentity == expectedSurvivorIdentity,
              state.survivorManifest.path == ONTGenotypeResultBundleManifest.filename,
              isSafeRelativePath(state.survivorCurrentWorkbook.path),
              isValidFileDescriptor(state.transaction.oldManifest),
              isValidFileDescriptor(state.transaction.newManifest),
              isValidFileDescriptor(
                  state.transaction.oldCurrentWorkbook
              ),
              isValidFileDescriptor(
                  state.transaction.newCurrentWorkbook
              ),
              isValidFileDescriptor(state.survivorManifest),
              isValidFileDescriptor(state.survivorCurrentWorkbook),
              state.transaction.transactionID == state.transactionID,
              state.transaction.finalBundlePath == state.finalBundlePath,
              state.survivorManifest == expectedSurvivorManifest,
              state.survivorCurrentWorkbook.path
                == expectedSurvivorCurrentWorkbook.path,
              state.terminalReceiptAction == expectedDisposition.action,
              state.terminalReceiptDetail == expectedDisposition.detail else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Invalid workbook cleanup state: \(stateURL.path)"
            )
        }
    }

    private static func lexicalPath(_ url: URL) -> String {
        NSString(string: url.path).standardizingPath
    }

    private static func identityBoundBundleNameIfPresent(
        _ requested: URL,
        parentDescriptor: Int32
    ) throws -> String? {
        let descriptor = Darwin.open(
            requested.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                requested.path,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFDIR else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The requested workbook bundle is not an identity-bound directory."
            )
        }
        let parent = requested.deletingLastPathComponent()
        let matchingNames = try directoryEntryNames(
            descriptor: parentDescriptor,
            displayedAt: parent
        ).filter { name in
            guard name.caseInsensitiveCompare(requested.lastPathComponent) == .orderedSame else {
                return false
            }
            var candidate = stat()
            let status = name.withCString {
                Darwin.fstatat(
                    parentDescriptor,
                    $0,
                    &candidate,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            return status == 0
                && candidate.st_mode & S_IFMT == S_IFDIR
                && candidate.st_dev == opened.st_dev
                && candidate.st_ino == opened.st_ino
        }
        guard matchingNames.count == 1, let actualName = matchingNames.first else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The requested workbook bundle has no unique identity-bound directory entry."
            )
        }
        return actualName
    }

    static func validateSurvivor(
        _ state: ONTGenotypeWorkbookCleanupState
    ) throws {
        let authority = try captureSurvivorAuthority(
            bundleURL: URL(
                fileURLWithPath: state.finalBundlePath,
                isDirectory: true
            ),
            expectedIdentity: state.survivorIdentity,
            expectedManifest: state.survivorManifest,
            expectedCurrentWorkbookPath: state.survivorCurrentWorkbook.path
        )
        guard authority.identity == state.survivorIdentity,
              authority.manifest == state.survivorManifest,
              authority.currentWorkbook == state.survivorCurrentWorkbook else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "The surviving generation no longer matches durable cleanup authority."
            )
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        return components.allSatisfy {
            DurableAtomicFileStore.isSinglePathComponent($0)
                && $0 != "."
                && $0 != ".."
        }
    }

    private static func isValidFileDescriptor(
        _ descriptor: ONTGenotypeWorkbookUpdateFileDescriptor
    ) -> Bool {
        descriptor.sizeBytes >= 0
            && isSafeRelativePath(descriptor.path)
            && descriptor.sha256.utf8.count == 64
            && descriptor.sha256.utf8.allSatisfy { byte in
                switch byte {
                case 48...57, 65...70, 97...102:
                    return true
                default:
                    return false
                }
            }
    }

    private static func readRelativeRegularFile(
        _ relativePath: String,
        beneath rootDescriptor: Int32,
        displayedAt rootURL: URL,
        collectDataLimit: Int64?
    ) throws -> (
        descriptor: ONTGenotypeWorkbookUpdateFileDescriptor,
        data: Data?
    ) {
        guard isSafeRelativePath(relativePath) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Unsafe survivor file path: \(relativePath)"
            )
        }
        let components = relativePath.split(separator: "/").map(String.init)
        var parentDescriptor = Darwin.dup(rootDescriptor)
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                rootURL.path,
                errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                    rootURL.appendingPathComponent(relativePath).path,
                    errno
                )
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = nextDescriptor
        }
        let filename = components.last!
        let fileDescriptor = filename.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                rootURL.appendingPathComponent(relativePath).path,
                errno
            )
        }
        defer { Darwin.close(fileDescriptor) }
        var before = stat()
        guard Darwin.fstat(fileDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Survivor file is not a regular file: \(relativePath)"
            )
        }
        if let collectDataLimit, before.st_size > collectDataLimit {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Survivor metadata file is too large: \(relativePath)"
            )
        }
        var hasher = SHA256()
        var collected = collectDataLimit == nil ? nil : Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                    rootURL.appendingPathComponent(relativePath).path,
                    errno
                )
            }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            collected?.append(chunk)
        }
        var after = stat()
        guard Darwin.fstat(fileDescriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Survivor file changed while it was measured: \(relativePath)"
            )
        }
        return (
            ONTGenotypeWorkbookUpdateFileDescriptor(
                path: relativePath,
                sizeBytes: Int64(before.st_size),
                sha256: hasher.finalize().map {
                    String(format: "%02x", $0)
                }.joined()
            ),
            collected
        )
    }

    private static func readRegularFileNoFollow(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= 16 * 1_024 * 1_024 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Workbook cleanup state is not a bounded regular file: \(url.path)"
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func fileIdentityIfPresent(_ url: URL) -> FileSystemObjectIdentity? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        return FileSystemObjectIdentity(info)
    }

    private static func requireIdentity(
        descriptor: Int32,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        path: String
    ) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              matches(info, expected) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Workbook cleanup parent identity changed: \(path)"
            )
        }
    }

    private static func matches(
        _ info: stat,
        _ expected: ONTGenotypeWorkbookUpdateDirectoryIdentity
    ) -> Bool {
        UInt64(bitPattern: Int64(info.st_dev)) == expected.device
            && UInt64(info.st_ino) == expected.inode
    }

    private static func directoryEntryNames(
        descriptor: Int32,
        displayedAt url: URL
    ) throws -> [String] {
        let enumerationDescriptor = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0,
              let stream = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 {
                Darwin.close(enumerationDescriptor)
            }
            throw CleanupTraversalError(
                detail: "Could not enumerate \(url.path) (errno \(errno))."
            )
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func removeContentsNoFollow(
        descriptor: Int32,
        displayedAt url: URL,
        failureInjector: (@Sendable (String) throws -> Void)?,
        cleanupOperations: ONTGenotypeWorkbookCleanupOperations
    ) throws {
        for name in try directoryEntryNames(descriptor: descriptor, displayedAt: url) {
            guard DurableAtomicFileStore.isSinglePathComponent(name) else {
                throw CleanupTraversalError(
                    detail: "Unsafe quarantine child name at \(url.path)."
                )
            }
            var info = stat()
            let inspect = name.withCString {
                Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard inspect == 0 else {
                if errno == ENOENT { continue }
                throw CleanupTraversalError(
                    detail: "Could not inspect \(url.appendingPathComponent(name).path) (errno \(errno))."
                )
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw CleanupTraversalError(
                        detail: "Could not open quarantine directory \(name) (errno \(errno))."
                    )
                }
                do {
                    defer { Darwin.close(child) }
                    var openedInfo = stat()
                    guard Darwin.fstat(child, &openedInfo) == 0,
                          openedInfo.st_dev == info.st_dev,
                          openedInfo.st_ino == info.st_ino else {
                        throw CleanupTraversalError(
                            detail: "Quarantine child \(name) changed before traversal."
                        )
                    }
                    try removeContentsNoFollow(
                        descriptor: child,
                        displayedAt: url.appendingPathComponent(name, isDirectory: true),
                        failureInjector: failureInjector,
                        cleanupOperations: cleanupOperations
                    )
                    var current = stat()
                    let currentStatus = name.withCString {
                        Darwin.fstatat(descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
                    }
                    guard currentStatus == 0,
                          current.st_dev == info.st_dev,
                          current.st_ino == info.st_ino,
                          name.withCString({
                              Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
                          }) == 0 else {
                        throw CleanupTraversalError(
                            detail: "Quarantine child \(name) changed before removal."
                        )
                    }
                }
            } else {
                try removeNondirectoryNoFollow(
                    named: name,
                    information: info,
                    beneath: descriptor,
                    displayedAt: url,
                    failureInjector: failureInjector,
                    cleanupOperations: cleanupOperations
                )
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CleanupTraversalError(
                detail: "Could not durably clean \(url.path) (errno \(errno))."
            )
        }
    }

    static func removeContentsNoFollowForTesting(
        at directoryURL: URL,
        failureInjector: (@Sendable (String) throws -> Void)? = nil,
        cleanupOperations: ONTGenotypeWorkbookCleanupOperations = .darwin
    ) throws {
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CleanupTraversalError(
                detail: "Could not open \(directoryURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(descriptor) }
        try removeContentsNoFollow(
            descriptor: descriptor,
            displayedAt: directoryURL,
            failureInjector: failureInjector,
            cleanupOperations: cleanupOperations
        )
    }

    private static func removeNondirectoryNoFollow(
        named name: String,
        information before: stat,
        beneath descriptor: Int32,
        displayedAt directoryURL: URL,
        failureInjector: (@Sendable (String) throws -> Void)?,
        cleanupOperations: ONTGenotypeWorkbookCleanupOperations
    ) throws {
        let displayedEntry = directoryURL.appendingPathComponent(name)
        let sourceDescriptor: Int32
        let sourceWitness: PortableExclusiveRename.RegularSourceWitness?
        if before.st_mode & S_IFMT == S_IFREG {
            sourceDescriptor = retryOnInterruption {
                name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard sourceDescriptor >= 0 else {
                if errno == ENOENT { return }
                throw CleanupTraversalError(
                    detail: "Could not open quarantine entry \(name) safely (errno \(errno))."
                )
            }
            var opened = stat()
            let openedStatus = retryOnInterruption {
                Darwin.fstat(sourceDescriptor, &opened)
            }
            guard openedStatus == 0 else {
                let code = errno
                _ = Darwin.close(sourceDescriptor)
                errno = code
                throw CleanupTraversalError(
                    detail: "Could not witness quarantine entry \(name) (errno \(code))."
                )
            }
            guard ONTGenotypeWorkbookCleanupRebaseClassifier
                .sameKernelIdentity(before, opened) else {
                _ = Darwin.close(sourceDescriptor)
                errno = ESTALE
                throw CleanupTraversalError(
                    detail: "Quarantine entry \(name) changed before it could be opened."
                )
            }
            sourceWitness = PortableExclusiveRename.RegularSourceWitness(
                descriptor: sourceDescriptor,
                expected: opened
            )
        } else {
            sourceDescriptor = -1
            sourceWitness = nil
        }
        defer {
            if sourceDescriptor >= 0 {
                let code = errno
                _ = Darwin.close(sourceDescriptor)
                errno = code
            }
        }

        try cleanupOperations.checkpoint(
            "source-witness-opened:\(displayedEntry.path)"
        )
        try failureInjector?(
            "before-workbook-cleanup-nondirectory-detach:"
                + displayedEntry.path
        )
        if let sourceWitness {
            var currentPath = stat()
            let pathStatus = name.withCString { sourceName in
                retryOnInterruption {
                    Darwin.fstatat(
                        descriptor,
                        sourceName,
                        &currentPath,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
            }
            var currentDescriptor = stat()
            let descriptorStatus = retryOnInterruption {
                Darwin.fstat(
                    sourceWitness.descriptor,
                    &currentDescriptor
                )
            }
            guard pathStatus == 0,
                  descriptorStatus == 0,
                  ONTGenotypeWorkbookCleanupRebaseClassifier
                    .identityAndStableMetadataMatch(
                        currentPath,
                        sourceWitness.expected
                    ),
                  ONTGenotypeWorkbookCleanupRebaseClassifier
                    .identityAndStableMetadataMatch(
                        currentDescriptor,
                        sourceWitness.expected
                    ) else {
                errno = ESTALE
                throw CleanupTraversalError(
                    detail: "Quarantine entry \(name) changed before safe detach."
                )
            }
        }
        let tombstone =
            ".lungfish-cleanup-entry-\(UUID().uuidString.lowercased())"
        let outcome = name.withCString { source in
            tombstone.withCString { destination in
                cleanupOperations.renameExclusive(
                    descriptor,
                    source,
                    descriptor,
                    destination,
                    UInt32(RENAME_EXCL),
                    sourceWitness
                )
            }
        }
        guard outcome.status == 0 else {
            let code = errno
            if code == ENOENT { return }
            errno = code
            throw CleanupTraversalError(
                detail: "Could not detach quarantine entry \(name) safely (errno \(code))."
            )
        }

        try cleanupOperations.checkpoint(
            "after-nondirectory-detach:\(displayedEntry.path)"
        )
        var original = stat()
        let originalStatus = name.withCString { originalName in
            retryOnInterruption {
                Darwin.fstatat(
                    descriptor,
                    originalName,
                    &original,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        }
        let originalNameIsAbsent = originalStatus == -1 && errno == ENOENT
        guard originalNameIsAbsent else {
            throw CleanupTraversalError(
                detail: "Quarantine entry \(name) survived or reappeared after detach."
            )
        }

        var postPath = stat()
        let inspectDetached = tombstone.withCString { detachedName in
            retryOnInterruption {
                Darwin.fstatat(
                    descriptor,
                    detachedName,
                    &postPath,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        }
        guard inspectDetached == 0 else {
            let code = errno
            throw CleanupTraversalError(
                detail: "Could not inspect detached quarantine entry \(name) (errno \(code))."
            )
        }

        let expectedDevice: dev_t
        let expectedInode: ino_t
        let expectedType: mode_t
        if let sourceWitness {
            var postDescriptor = stat()
            guard retryOnInterruption({
                Darwin.fstat(sourceWitness.descriptor, &postDescriptor)
            }) == 0 else {
                let code = errno
                throw CleanupTraversalError(
                    detail: "Could not revalidate detached quarantine entry \(name) (errno \(code))."
                )
            }
            switch ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: sourceWitness.expected,
                postDescriptor: postDescriptor,
                postPath: postPath,
                mechanism: outcome.mechanism,
                originalNameIsAbsent: originalNameIsAbsent
            ) {
            case .exact(let device, let inode),
                 .rebased(let device, let inode):
                expectedDevice = device
                expectedInode = inode
            case .reject:
                throw CleanupTraversalError(
                    detail: "Quarantine entry \(name) was substituted before safe detach."
                )
            }
            expectedType = sourceWitness.expected.st_mode & S_IFMT
        } else {
            guard before.st_dev == postPath.st_dev,
                  before.st_ino == postPath.st_ino,
                  before.st_mode & S_IFMT == postPath.st_mode & S_IFMT else {
                throw CleanupTraversalError(
                    detail: "Quarantine entry \(name) was substituted before safe detach."
                )
            }
            expectedDevice = postPath.st_dev
            expectedInode = postPath.st_ino
            expectedType = before.st_mode & S_IFMT
        }

        try failureInjector?(
            "before-workbook-cleanup-nondirectory-unlink:"
                + directoryURL.appendingPathComponent(tombstone).path
        )
        try cleanupOperations.checkpoint(
            "before-final-tombstone-witness:"
                + directoryURL.appendingPathComponent(tombstone).path
        )

        try tombstone.withCString { detachedName in
            var finalPath = stat()
            let finalPathStatus = retryOnInterruption {
                Darwin.fstatat(
                    descriptor,
                    detachedName,
                    &finalPath,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard finalPathStatus == 0,
                  finalPath.st_dev == expectedDevice,
                  finalPath.st_ino == expectedInode,
                  finalPath.st_mode & S_IFMT == expectedType else {
                throw CleanupTraversalError(
                    detail: "Detached quarantine entry \(name) changed before removal."
                )
            }
            if let sourceWitness {
                var finalDescriptor = stat()
                guard retryOnInterruption({
                    Darwin.fstat(
                        sourceWitness.descriptor,
                        &finalDescriptor
                    )
                }) == 0,
                      finalDescriptor.st_dev == expectedDevice,
                      finalDescriptor.st_ino == expectedInode,
                      finalDescriptor.st_mode & S_IFMT == expectedType else {
                    throw CleanupTraversalError(
                        detail: "Detached quarantine entry \(name) changed before removal."
                    )
                }
            }

            // There is intentionally no injected callback, actor hop, or
            // allocation between these final descriptor/path witnesses and
            // the name-based unlink syscall.
            let removeStatus = retryOnInterruption {
                Darwin.unlinkat(descriptor, detachedName, 0)
            }
            guard removeStatus == 0 else {
                let code = errno
                throw CleanupTraversalError(
                    detail: "Could not remove detached quarantine entry \(name) (errno \(code))."
                )
            }
        }
        try cleanupOperations.checkpoint(
            "after-nondirectory-unlink:"
                + directoryURL.appendingPathComponent(tombstone).path
        )
    }

    private static func retryOnInterruption(
        _ operation: () -> Int32
    ) -> Int32 {
        while true {
            let result = operation()
            if result == -1, errno == EINTR { continue }
            return result
        }
    }
}
