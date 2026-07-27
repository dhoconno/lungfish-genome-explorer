import CryptoKit
import Darwin
import Foundation

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
    public let decision: ONTGenotypeWorkbookCleanupDecision
    public let retryState: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = 2,
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

    static func states(for bundleURL: URL) throws -> [(URL, ONTGenotypeWorkbookCleanupState)] {
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        let prefix = ".\(bundle.lastPathComponent).workbook-cleanup-state-"
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted()
        return try names.map { name in
            guard DurableAtomicFileStore.isSinglePathComponent(name) else {
                throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                    "unsafe workbook cleanup-state name: \(name)"
                )
            }
            let url = parent.appendingPathComponent(name)
            let data = try readRegularFileNoFollow(url)
            let state = try decoder.decode(ONTGenotypeWorkbookCleanupState.self, from: data)
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
        expectedState: ONTGenotypeWorkbookCleanupState
    ) throws {
        let parent = stateURL.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
        defer { Darwin.close(parentDescriptor) }
        var info = stat()
        let inspect = stateURL.lastPathComponent.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard inspect == 0 else {
            if errno == ENOENT { return }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(stateURL.path, errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              try decoder.decode(
                  ONTGenotypeWorkbookCleanupState.self,
                  from: readRegularFileNoFollow(stateURL)
              ) == expectedState else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Workbook cleanup state was substituted before retirement: \(stateURL.path)"
            )
        }
        var current = stat()
        let currentStatus = stateURL.lastPathComponent.withCString {
            Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard currentStatus == 0,
              current.st_dev == info.st_dev,
              current.st_ino == info.st_ino,
              stateURL.lastPathComponent.withCString({
                  Darwin.unlinkat(parentDescriptor, $0, 0)
              }) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Workbook cleanup state changed before retirement: \(stateURL.path)"
            )
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(parent.path, errno)
        }
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
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        do {
            try validateSurvivor(state)
        } catch {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "The surviving workbook generation is unavailable or changed: "
                    + error.localizedDescription
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
                try removeState(at: stateURL, expectedState: state)
                return
            }
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Could not inspect cleanup quarantine (errno \(errno))."
            )
        }
        guard matches(entryInfo, state.quarantineIdentity) else {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Cleanup quarantine identity changed before traversal."
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
                reason: "Could not open cleanup quarantine without following links (errno \(errno))."
            )
        }
        defer { Darwin.close(descriptor) }
        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              matches(openedInfo, state.quarantineIdentity) else {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: "Opened cleanup quarantine identity does not match durable state."
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
                displayedAt: quarantine
            )
            var finalInfo = stat()
            let finalStatus = quarantine.lastPathComponent.withCString {
                Darwin.fstatat(parentDescriptor, $0, &finalInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard finalStatus == 0,
                  matches(finalInfo, state.quarantineIdentity),
                  quarantine.lastPathComponent.withCString({
                      Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                  }) == 0 else {
                throw CleanupTraversalError(
                    detail: "Cleanup quarantine changed before final removal (errno \(errno))."
                )
            }
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw CleanupTraversalError(
                    detail: "Cleanup quarantine removal durability is uncertain (errno \(errno))."
                )
            }
            try removeState(at: stateURL, expectedState: state)
        } catch let error as ONTGenotypeWorkbookUpdateRecoveryError {
            throw error
        } catch {
            try throwWarning(
                state: state,
                stateURL: stateURL,
                reason: error.localizedDescription
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
        reason: String
    ) throws -> Never {
        let warningURL = try recordWarning(
            state: state,
            stateURL: stateURL,
            reason: reason
        )
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
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        let expectedStateURL = self.stateURL(
            transactionID: state.transactionID,
            bundleURL: bundle
        ).standardizedFileURL
        let expectedQuarantine = quarantineURL(
            transactionID: state.transactionID,
            parent: parent
        ).standardizedFileURL
        guard state.schemaVersion == 2,
              state.retryState == "cleanup-pending",
              DurableAtomicFileStore.isSinglePathComponent(state.transactionID),
              URL(fileURLWithPath: state.finalBundlePath).standardizedFileURL == bundle,
              stateURL.standardizedFileURL == expectedStateURL,
              URL(fileURLWithPath: state.quarantinePath).standardizedFileURL
                == expectedQuarantine,
              URL(fileURLWithPath: state.sourceRootPath).deletingLastPathComponent()
                .standardizedFileURL == parent,
              state.parentIdentity.path == parent.path,
              state.sourceIdentity.path == state.sourceRootPath,
              state.quarantineIdentity.path == state.quarantinePath,
              state.survivorIdentity.path == state.finalBundlePath,
              state.survivorManifest.path == ONTGenotypeResultBundleManifest.filename,
              isSafeRelativePath(state.survivorCurrentWorkbook.path),
              state.sourceIdentity.device == state.quarantineIdentity.device,
              state.sourceIdentity.inode == state.quarantineIdentity.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.invalidTransaction(
                "Invalid workbook cleanup state: \(stateURL.path)"
            )
        }
    }

    private static func validateSurvivor(
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
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
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
        displayedAt url: URL
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
                        displayedAt: url.appendingPathComponent(name, isDirectory: true)
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
                let status = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                guard status == 0 || errno == ENOENT else {
                    throw CleanupTraversalError(
                        detail: "Could not remove quarantine entry \(name) (errno \(errno))."
                    )
                }
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CleanupTraversalError(
                detail: "Could not durably clean \(url.path) (errno \(errno))."
            )
        }
    }
}
