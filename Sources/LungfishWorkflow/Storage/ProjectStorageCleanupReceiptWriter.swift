import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum ProjectStorageCleanupPreparationError:
    Error,
    LocalizedError,
    Equatable
{
    case emptySelection
    case unsafeProject(String)
    case unsafeSource(String)
    case sourceNotRemovable(String)
    case sourceIdentityChanged(String)
    case unsafeInventoryEntry(String)
    case invalidAttestation(String)
    case selectionAuthorityChanged(String)
    case overlappingSelection(String, String)
    case parameterRepresentationOverflow(field: String, path: String)
    case operationAlreadyExists(UUID)
    case publicationDurabilityUncertain(String, Int32)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Project storage cleanup has no confirmed selections."
        case .unsafeProject(let path):
            return "Project storage cleanup project is unsafe: \(path)"
        case .unsafeSource(let path):
            return "Project storage cleanup source is unsafe: \(path)"
        case .sourceNotRemovable(let path):
            return "Project storage cleanup source is not removable: \(path)"
        case .sourceIdentityChanged(let path):
            return "Project storage cleanup source identity changed: \(path)"
        case .unsafeInventoryEntry(let path):
            return "Project storage cleanup inventory entry is unsafe: \(path)"
        case .invalidAttestation(let path):
            return "Project storage cleanup attestation is invalid: \(path)"
        case .selectionAuthorityChanged(let path):
            return "Project storage cleanup selection is no longer "
                + "authoritative: \(path)"
        case .overlappingSelection(let ancestor, let descendant):
            return "Project storage cleanup selections overlap: \(ancestor) "
                + "contains \(descendant)."
        case .parameterRepresentationOverflow(let field, let path):
            return "Project storage cleanup \(field) cannot be represented "
                + "exactly for \(path)."
        case .operationAlreadyExists(let id):
            return "Project storage cleanup already exists for \(id)."
        case .publicationDurabilityUncertain(let path, let code):
            return "Project storage cleanup was published at \(path), but "
                + "directory durability is uncertain (errno \(code))."
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}

public struct ProjectStorageCleanupReceiptWriter: Sendable {
    public static let collectionDirectoryName = "storage-cleanups"
    public static let journalFileName = "journal.json"
    public static let provenanceFileName = "provenance.json"

    struct Operations: Sendable {
        var cancellationCheck: @Sendable () throws -> Void
        var didHashRelativePath: @Sendable (String) -> Void
        var didReadAttestationProvenance: @Sendable (String) -> Void
        var afterCreateStaging: @Sendable () throws -> Void
        var beforePublish: @Sendable () throws -> Void
        var syncFile: @Sendable (Int32) -> Int32
        var syncDirectory: @Sendable (Int32) -> Int32
        var now: @Sendable () -> Date
        var authoritativeScan:
            @Sendable (URL) throws -> ProjectStorageScanResult

        init(
            cancellationCheck:
                @escaping @Sendable () throws -> Void = {
                    try Task.checkCancellation()
                },
            didHashRelativePath:
                @escaping @Sendable (String) -> Void = { _ in },
            didReadAttestationProvenance:
                @escaping @Sendable (String) -> Void = { _ in },
            afterCreateStaging:
                @escaping @Sendable () throws -> Void = {},
            beforePublish:
                @escaping @Sendable () throws -> Void = {},
            syncFile:
                @escaping @Sendable (Int32) -> Int32 = {
                    Darwin.fsync($0)
                },
            syncDirectory:
                @escaping @Sendable (Int32) -> Int32 = {
                    Darwin.fsync($0)
                },
            now: @escaping @Sendable () -> Date = { Date() },
            authoritativeScan:
                @escaping @Sendable (URL) throws
                    -> ProjectStorageScanResult = {
                        try ProjectStorageScanner().scan(projectURL: $0)
                    }
        ) {
            self.cancellationCheck = cancellationCheck
            self.didHashRelativePath = didHashRelativePath
            self.didReadAttestationProvenance =
                didReadAttestationProvenance
            self.afterCreateStaging = afterCreateStaging
            self.beforePublish = beforePublish
            self.syncFile = syncFile
            self.syncDirectory = syncDirectory
            self.now = now
            self.authoritativeScan = authoritativeScan
        }
    }

    private struct FileSnapshot: Hashable {
        let identity: FileSystemObjectIdentity
        let logicalSize: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ information: stat) {
            identity = FileSystemObjectIdentity(from: information)
            logicalSize = UInt64(information.st_size)
            modifiedSeconds = information.st_mtimespec.tv_sec
            modifiedNanoseconds = information.st_mtimespec.tv_nsec
            changedSeconds = information.st_ctimespec.tv_sec
            changedNanoseconds = information.st_ctimespec.tv_nsec
        }
    }

    private struct DirectorySnapshot: Equatable {
        let identity: FileSystemObjectIdentity
        let size: Int64
        let links: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ information: stat) {
            identity = FileSystemObjectIdentity(from: information)
            size = information.st_size
            links = information.st_nlink
            modifiedSeconds = information.st_mtimespec.tv_sec
            modifiedNanoseconds = information.st_mtimespec.tv_nsec
            changedSeconds = information.st_ctimespec.tv_sec
            changedNanoseconds = information.st_ctimespec.tv_nsec
        }
    }

    private struct ClassificationEvidence: Encodable {
        let relativePath: String
        let identity: FileSystemObjectIdentity
        let category: String
        let logicalBytes: UInt64
        let allocatedBytes: UInt64
        let disposition: String
        let code: String
        let reason: String
    }

    private struct CachedHash {
        let snapshot: FileSnapshot
        let sha256: String
    }

    private let operations: Operations

    public init() {
        operations = .init()
    }

    init(operations: Operations) {
        self.operations = operations
    }

    public func prepareConfirmedCleanup(
        _ request: ProjectStorageCleanupPreparationRequest
    ) throws -> ProjectStorageCleanupPreparation {
        try operations.cancellationCheck()
        guard !request.selectedEntries.isEmpty else {
            throw ProjectStorageCleanupPreparationError.emptySelection
        }
        let project = request.projectURL.standardizedFileURL
        let projectDescriptor: Int32
        do {
            projectDescriptor =
                try NoFollowFileSystem.openDirectoryHierarchy(project)
        } catch {
            throw ProjectStorageCleanupPreparationError.unsafeProject(
                project.path
            )
        }
        defer { Darwin.close(projectDescriptor) }
        var projectInformation = stat()
        guard Darwin.fstat(projectDescriptor, &projectInformation) == 0,
              projectInformation.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(from: projectInformation)
                == request.projectIdentity else {
            throw ProjectStorageCleanupPreparationError.unsafeProject(
                project.path
            )
        }

        let attestations = try attestationMap(
            request.attestedInventories,
            selectedEntries: request.selectedEntries,
            project: project
        )
        var hashCache: [FileSystemObjectIdentity: CachedHash] = [:]
        var journalItems: [ProjectStorageCleanupJournal.Item] = []
        let selected = request.selectedEntries.sorted {
            $0.relativePath < $1.relativePath
        }
        guard Set(selected.map(\.relativePath)).count == selected.count else {
            throw ProjectStorageCleanupPreparationError.unsafeSource(
                "duplicate selected path"
            )
        }
        try rejectOverlappingSelections(selected)
        let authoritative = try operations.authoritativeScan(project)
        guard authoritative.projectIdentity == request.projectIdentity else {
            throw ProjectStorageCleanupPreparationError.unsafeProject(
                project.path
            )
        }
        let authoritativeEntries = Dictionary(
            uniqueKeysWithValues: authoritative.entries.map {
                ($0.relativePath, $0)
            }
        )
        for entry in selected {
            guard authoritativeEntries[entry.relativePath] == entry else {
                throw ProjectStorageCleanupPreparationError
                    .selectionAuthorityChanged(entry.relativePath)
            }
        }
        for entry in selected {
            try operations.cancellationCheck()
            guard entry.classification.isRemovable else {
                throw ProjectStorageCleanupPreparationError
                    .sourceNotRemovable(entry.relativePath)
            }
            journalItems.append(
                try prepareItem(
                    entry,
                    cleanupID: request.cleanupID,
                    project: project,
                    projectDescriptor: projectDescriptor,
                    attested: attestations[entry.relativePath] ?? [:],
                    hashCache: &hashCache
                )
            )
        }
        try operations.cancellationCheck()

        let completedAt = operations.now()
        let wallTime = max(
            0,
            completedAt.timeIntervalSince(request.startedAt)
        )
        let inventoryValue = ParameterValue.array(
            try journalItems.map { try $0.parameterValue() }
        )
        let options = mergedOptions(
            request.options,
            project: project,
            selected: selected,
            inventory: inventoryValue
        )
        let reproducibleCommand = request.argv
            .map(shellEscapeForCleanup)
            .joined(separator: " ")
        let journal = ProjectStorageCleanupJournal(
            cleanupID: request.cleanupID,
            projectRoot: project.path,
            projectIdentity: request.projectIdentity,
            startedAt: request.startedAt,
            completedAt: completedAt,
            workflowName: request.workflowName,
            workflowVersion: request.workflowVersion,
            toolName: request.toolName,
            toolVersion: request.toolVersion,
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: request.runtimeIdentity,
            attestationSources: request.attestedInventories
                .sorted {
                    $0.sourceRelativePath < $1.sourceRelativePath
                }
                .map(ProjectStorageCleanupJournal.AttestationSource.init),
            items: journalItems,
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            stderr: ""
        )
        let journalData = try ProvenanceJSON.encoder.encode(journal)
        let operationDirectory = operationDirectoryURL(
            projectURL: project,
            cleanupID: request.cleanupID
        )
        let journalURL = operationDirectory.appendingPathComponent(
            Self.journalFileName
        )
        let provenanceURL = operationDirectory.appendingPathComponent(
            Self.provenanceFileName
        )
        let journalDescriptor = ProvenanceFileDescriptor(
            path: journalURL.path,
            checksumSHA256: sha256(journalData),
            fileSize: UInt64(journalData.count),
            format: .json,
            role: .output
        )
        let inventoryInputs = journalItems.flatMap { item in
            item.inventory.map { descriptor in
                ProvenanceFileDescriptor(
                    path: project.appendingPathComponent(
                        item.sourceRelativePath
                    ).appendingPathComponent(
                        descriptor.relativePath
                    ).path,
                    checksumSHA256: descriptor.sha256,
                    fileSize: descriptor.logicalSize,
                    role: .input,
                    originPath:
                        item.sourceRelativePath + "/"
                        + descriptor.relativePath
                )
            }
        }
        let attestationInputs = request.attestedInventories
            .sorted { $0.sourceRelativePath < $1.sourceRelativePath }
            .map {
                ProvenanceFileDescriptor(
                    path: $0.sourceProvenancePath,
                    checksumSHA256:
                        $0.sourceProvenanceChecksumSHA256.lowercased(),
                    fileSize: $0.sourceProvenanceFileSize,
                    format: .json,
                    role: .input,
                    originPath: $0.sourceRelativePath
                )
            }
        let inputs = attestationInputs + inventoryInputs
        var resolved = options.defaults
        resolved.merge(options.resolvedDefaults) { _, new in new }
        resolved.merge(options.explicit) { _, new in new }
        let step = ProvenanceStep(
            toolName: request.toolName,
            toolVersion: request.toolVersion,
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            resolvedOptions: resolved,
            runtimeIdentity: request.runtimeIdentity,
            inputs: inputs,
            outputs: [journalDescriptor],
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            stderr: "",
            startedAt: request.startedAt,
            completedAt: completedAt
        )
        let provenance = ProvenanceEnvelope(
            id: request.cleanupID,
            createdAt: completedAt,
            workflowName: request.workflowName,
            workflowVersion: request.workflowVersion,
            toolName: request.toolName,
            toolVersion: request.toolVersion,
            argv: request.argv,
            durableReplayArgv: request.durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: request.runtimeIdentity,
            files: inputs,
            output: journalDescriptor,
            outputs: [journalDescriptor],
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0,
            stderr: ""
        )
        let provenanceData = try ProvenanceJSON.encoder.encode(provenance)
        try operations.cancellationCheck()
        for item in journalItems {
            guard try FileSystemObjectIdentity.noFollow(
                project.appendingPathComponent(item.sourceRelativePath)
            ) == item.sourceIdentity else {
                throw ProjectStorageCleanupPreparationError
                    .sourceIdentityChanged(item.sourceRelativePath)
            }
        }
        try publish(
            cleanupID: request.cleanupID,
            projectURL: project,
            expectedProjectIdentity: request.projectIdentity,
            payloads: [
                Self.journalFileName: journalData,
                Self.provenanceFileName: provenanceData,
            ]
        )
        return .init(
            operationDirectoryURL: operationDirectory,
            journalURL: journalURL,
            provenanceURL: provenanceURL,
            journal: journal,
            provenance: provenance
        )
    }

    private func prepareItem(
        _ entry: ProjectStorageEntry,
        cleanupID: UUID,
        project: URL,
        projectDescriptor: Int32,
        attested: [String: ProjectStorageCleanupInventoryEntry],
        hashCache: inout [FileSystemObjectIdentity: CachedHash]
    ) throws -> ProjectStorageCleanupJournal.Item {
        let sourceDescriptor = try openRelativeDirectory(
            entry.relativePath,
            projectDescriptor: projectDescriptor,
            projectURL: project
        )
        defer { Darwin.close(sourceDescriptor) }
        var sourceInformation = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceInformation) == 0,
              sourceInformation.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(from: sourceInformation)
                == entry.identity else {
            throw ProjectStorageCleanupPreparationError
                .sourceIdentityChanged(entry.relativePath)
        }
        var inventory: [ProjectStorageCleanupInventoryEntry] = []
        try inventoryDirectory(
            descriptor: sourceDescriptor,
            displayURL: project.appendingPathComponent(
                entry.relativePath,
                isDirectory: true
            ),
            relativePrefix: "",
            attested: attested,
            hashCache: &hashCache,
            inventory: &inventory
        )
        inventory.sort { $0.relativePath < $1.relativePath }
        guard Set(attested.keys).isSubset(
            of: Set(inventory.map(\.relativePath))
        ) else {
            throw ProjectStorageCleanupPreparationError
                .invalidAttestation(entry.relativePath)
        }
        try operations.cancellationCheck()
        var finalSourceInformation = stat()
        guard Darwin.fstat(
            sourceDescriptor,
            &finalSourceInformation
        ) == 0,
            DirectorySnapshot(finalSourceInformation)
                == DirectorySnapshot(sourceInformation),
            try FileSystemObjectIdentity.noFollow(
                project.appendingPathComponent(entry.relativePath)
            ) == entry.identity else {
            throw ProjectStorageCleanupPreparationError
                .sourceIdentityChanged(entry.relativePath)
        }
        return .init(
            id: stableItemID(
                cleanupID: cleanupID,
                relativePath: entry.relativePath
            ),
            sourceRelativePath: entry.relativePath,
            sourceIdentity: entry.identity,
            sourceCategory: entry.category,
            classification: entry.classification,
            classificationEvidenceDigest: try classificationDigest(entry),
            inventory: inventory,
            aggregateTreeDigest: try aggregateDigest(inventory)
        )
    }

    private func inventoryDirectory(
        descriptor: Int32,
        displayURL: URL,
        relativePrefix: String,
        attested: [String: ProjectStorageCleanupInventoryEntry],
        hashCache: inout [FileSystemObjectIdentity: CachedHash],
        inventory: inout [ProjectStorageCleanupInventoryEntry]
    ) throws {
        try operations.cancellationCheck()
        var beforeInformation = stat()
        guard Darwin.fstat(descriptor, &beforeInformation) == 0,
              beforeInformation.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(displayURL.path)
        }
        let before = DirectorySnapshot(beforeInformation)
        for name in try directoryEntryNames(
            descriptor: descriptor,
            displayURL: displayURL
        ) {
            try operations.cancellationCheck()
            let relative = relativePrefix.isEmpty
                ? name
                : relativePrefix + "/" + name
            var information = stat()
            let inspectStatus = name.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &information,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspectStatus == 0 else {
                throw ProjectStorageCleanupPreparationError
                    .unsafeInventoryEntry(
                        displayURL.appendingPathComponent(name).path
                    )
            }
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw ProjectStorageCleanupPreparationError
                        .unsafeInventoryEntry(
                            displayURL.appendingPathComponent(name).path
                        )
                }
                do {
                    var openedInformation = stat()
                    guard Darwin.fstat(child, &openedInformation) == 0,
                          FileSystemObjectIdentity(from: openedInformation)
                            == FileSystemObjectIdentity(from: information)
                    else {
                        throw ProjectStorageCleanupPreparationError
                            .unsafeInventoryEntry(
                                displayURL.appendingPathComponent(name).path
                            )
                    }
                    try inventoryDirectory(
                        descriptor: child,
                        displayURL:
                            displayURL.appendingPathComponent(
                                name,
                                isDirectory: true
                            ),
                        relativePrefix: relative,
                        attested: attested,
                        hashCache: &hashCache,
                        inventory: &inventory
                    )
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(child)
            case S_IFREG:
                inventory.append(
                    try inventoryFile(
                        named: name,
                        directoryDescriptor: descriptor,
                        displayURL: displayURL,
                        relativePath: relative,
                        inspectedInformation: information,
                        attested: attested[relative],
                        hashCache: &hashCache
                    )
                )
            default:
                throw ProjectStorageCleanupPreparationError
                    .unsafeInventoryEntry(
                        displayURL.appendingPathComponent(name).path
                    )
            }
        }
        var afterInformation = stat()
        guard Darwin.fstat(descriptor, &afterInformation) == 0,
              DirectorySnapshot(afterInformation) == before else {
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(displayURL.path)
        }
    }

    private func inventoryFile(
        named name: String,
        directoryDescriptor: Int32,
        displayURL: URL,
        relativePath: String,
        inspectedInformation: stat,
        attested: ProjectStorageCleanupInventoryEntry?,
        hashCache: inout [FileSystemObjectIdentity: CachedHash]
    ) throws -> ProjectStorageCleanupInventoryEntry {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        let fileURL = displayURL.appendingPathComponent(name)
        guard descriptor >= 0 else {
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(fileURL.path)
        }
        defer { Darwin.close(descriptor) }
        var beforeInformation = stat()
        guard Darwin.fstat(descriptor, &beforeInformation) == 0,
              beforeInformation.st_mode & S_IFMT == S_IFREG,
              FileSystemObjectIdentity(from: beforeInformation)
                == FileSystemObjectIdentity(from: inspectedInformation),
              beforeInformation.st_size >= 0,
              beforeInformation.st_blocks >= 0 else {
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(fileURL.path)
        }
        let blocks = UInt64(beforeInformation.st_blocks)
        guard blocks <= UInt64.max / 512 else {
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(fileURL.path)
        }
        let snapshot = FileSnapshot(beforeInformation)
        let allocated = blocks * 512
        let checksum: String
        if let attested {
            guard attested.relativePath == relativePath,
                  attested.logicalSize == snapshot.logicalSize,
                  attested.allocatedSize == allocated,
                  attested.device == snapshot.identity.device,
                  attested.inode == snapshot.identity.inode,
                  attested.modifiedSeconds
                    == Int64(snapshot.modifiedSeconds),
                  attested.modifiedNanoseconds
                    == Int64(snapshot.modifiedNanoseconds),
                  attested.changedSeconds
                    == Int64(snapshot.changedSeconds),
                  attested.changedNanoseconds
                    == Int64(snapshot.changedNanoseconds),
                  isSHA256(attested.sha256) else {
                throw ProjectStorageCleanupPreparationError
                    .invalidAttestation(relativePath)
            }
            checksum = attested.sha256.lowercased()
            if let cached = hashCache[snapshot.identity] {
                guard cached.snapshot == snapshot,
                      cached.sha256 == checksum else {
                    throw ProjectStorageCleanupPreparationError
                        .invalidAttestation(relativePath)
                }
            }
            hashCache[snapshot.identity] = .init(
                snapshot: snapshot,
                sha256: checksum
            )
        } else if let cached = hashCache[snapshot.identity] {
            guard cached.snapshot == snapshot else {
                throw ProjectStorageCleanupPreparationError
                    .sourceIdentityChanged(relativePath)
            }
            checksum = cached.sha256
        } else {
            operations.didHashRelativePath(relativePath)
            checksum = try hash(
                descriptor: descriptor,
                displayPath: fileURL.path
            )
            hashCache[snapshot.identity] = .init(
                snapshot: snapshot,
                sha256: checksum
            )
        }
        var afterInformation = stat()
        guard Darwin.fstat(descriptor, &afterInformation) == 0,
              FileSnapshot(afterInformation) == snapshot else {
            throw ProjectStorageCleanupPreparationError
                .sourceIdentityChanged(relativePath)
        }
        return .init(
            relativePath: relativePath,
            logicalSize: snapshot.logicalSize,
            allocatedSize: allocated,
            sha256: checksum,
            device: snapshot.identity.device,
            inode: snapshot.identity.inode,
            modifiedSeconds: Int64(snapshot.modifiedSeconds),
            modifiedNanoseconds: Int64(snapshot.modifiedNanoseconds),
            changedSeconds: Int64(snapshot.changedSeconds),
            changedNanoseconds: Int64(snapshot.changedNanoseconds)
        )
    }

    private func hash(
        descriptor: Int32,
        displayPath: String
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try operations.cancellationCheck()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor,
                    $0.baseAddress,
                    $0.count
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProjectStorageCleanupPreparationError.systemFailure(
                    path: displayPath,
                    operation: "hash cleanup inventory file",
                    code: errno
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }
            .joined()
    }

    private func publish(
        cleanupID: UUID,
        projectURL: URL,
        expectedProjectIdentity: FileSystemObjectIdentity,
        payloads: [String: Data]
    ) throws {
        let projectDescriptor: Int32
        do {
            projectDescriptor =
                try NoFollowFileSystem.openDirectoryHierarchy(projectURL)
        } catch {
            throw ProjectStorageCleanupPreparationError.unsafeProject(
                projectURL.path
            )
        }
        defer { Darwin.close(projectDescriptor) }
        var projectInformation = stat()
        guard Darwin.fstat(projectDescriptor, &projectInformation) == 0,
              FileSystemObjectIdentity(from: projectInformation)
                == expectedProjectIdentity else {
            throw ProjectStorageCleanupPreparationError.unsafeProject(
                projectURL.path
            )
        }
        let history = try openOrCreateDirectory(
            named: ProjectOperationHistoryWriter.historyDirectoryName,
            parentDescriptor: projectDescriptor,
            parentURL: projectURL,
            mode: S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH,
            requiresPrivatePermissions: false
        )
        defer { Darwin.close(history) }
        let historyURL = projectURL.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        )
        let collection = try openOrCreateDirectory(
            named: Self.collectionDirectoryName,
            parentDescriptor: history,
            parentURL: historyURL,
            mode: S_IRWXU,
            requiresPrivatePermissions: true
        )
        defer { Darwin.close(collection) }
        let collectionURL = historyURL.appendingPathComponent(
            Self.collectionDirectoryName,
            isDirectory: true
        )
        let operationName = cleanupID.uuidString.lowercased()
        let stagingName =
            ".\(operationName).staging-\(UUID().uuidString.lowercased())"
        let createStatus = stagingName.withCString {
            Darwin.mkdirat(collection, $0, S_IRWXU)
        }
        guard createStatus == 0 else {
            throw ProjectStorageCleanupPreparationError.systemFailure(
                path: collectionURL.appendingPathComponent(stagingName).path,
                operation: "create storage cleanup history staging",
                code: errno
            )
        }
        let stagingURL = collectionURL.appendingPathComponent(
            stagingName,
            isDirectory: true
        )
        var createdInformation = stat()
        let inspectCreatedStatus = stagingName.withCString {
            Darwin.fstatat(
                collection,
                $0,
                &createdInformation,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectCreatedStatus == 0,
              createdInformation.st_mode & S_IFMT == S_IFDIR else {
            try rollbackNewStaging(
                named: stagingName,
                expectedIdentity: nil,
                collectionDescriptor: collection,
                stagingURL: stagingURL,
                collectionURL: collectionURL
            )
            throw ProjectStorageCleanupPreparationError
                .unsafeSource(stagingURL.path)
        }
        let createdIdentity = FileSystemObjectIdentity(
            from: createdInformation
        )
        do {
            try operations.afterCreateStaging()
        } catch {
            try rollbackNewStaging(
                named: stagingName,
                expectedIdentity: createdIdentity,
                collectionDescriptor: collection,
                stagingURL: stagingURL,
                collectionURL: collectionURL
            )
            throw error
        }
        let staging = stagingName.withCString {
            Darwin.openat(
                collection,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard staging >= 0 else {
            let openError =
                ProjectStorageCleanupPreparationError
                    .unsafeSource(stagingURL.path)
            try rollbackNewStaging(
                named: stagingName,
                expectedIdentity: createdIdentity,
                collectionDescriptor: collection,
                stagingURL: stagingURL,
                collectionURL: collectionURL
            )
            throw openError
        }
        defer { Darwin.close(staging) }
        var stagingInformation = stat()
        guard Darwin.fstat(staging, &stagingInformation) == 0,
              stagingInformation.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(from: stagingInformation)
                == createdIdentity,
              stagingInformation.st_uid == Darwin.geteuid(),
              stagingInformation.st_nlink >= 2,
              stagingInformation.st_mode & 0o777 == 0o700 else {
            let validationError =
                ProjectStorageCleanupPreparationError
                    .unsafeSource(stagingURL.path)
            try rollbackStaging(
                named: stagingName,
                payloadNames: [],
                expectedIdentity: createdIdentity,
                stagingDescriptor: staging,
                collectionDescriptor: collection,
                stagingURL: stagingURL,
                collectionURL: collectionURL
            )
            throw validationError
        }
        let stagingIdentity = createdIdentity
        var published = false
        do {
            try syncDirectory(
                collection,
                path: collectionURL.path,
                operation: "fsync storage cleanup staging entry"
            )
            let store = DurableAtomicFileStore(
                operations: .init(
                    syncFile: operations.syncFile,
                    syncDirectory: operations.syncDirectory,
                    syncRollbackDirectory: operations.syncDirectory
                )
            )
            for name in payloads.keys.sorted() {
                try operations.cancellationCheck()
                _ = try store.create(
                    payloads[name]!,
                    named: name,
                    inOpenDirectory: staging,
                    displayedAt: stagingURL
                )
            }
            try syncDirectory(
                staging,
                path: stagingURL.path,
                operation: "fsync storage cleanup payloads"
            )
            try operations.beforePublish()
            let renameStatus = stagingName.withCString { stagingNamePointer in
                operationName.withCString { operationNamePointer in
                    Darwin.renameatx_np(
                        collection,
                        stagingNamePointer,
                        collection,
                        operationNamePointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameStatus == 0 else {
                if errno == EEXIST {
                    throw ProjectStorageCleanupPreparationError
                        .operationAlreadyExists(cleanupID)
                }
                throw ProjectStorageCleanupPreparationError.systemFailure(
                    path: collectionURL
                        .appendingPathComponent(operationName).path,
                    operation: "publish storage cleanup history",
                    code: errno
                )
            }
            published = true
            guard operations.syncDirectory(collection) == 0 else {
                throw ProjectStorageCleanupPreparationError
                    .publicationDurabilityUncertain(
                        collectionURL
                            .appendingPathComponent(operationName).path,
                        errno
                    )
            }
        } catch {
            if !published {
                try rollbackStaging(
                    named: stagingName,
                    payloadNames: Array(payloads.keys),
                    expectedIdentity: stagingIdentity,
                    stagingDescriptor: staging,
                    collectionDescriptor: collection,
                    stagingURL: stagingURL,
                    collectionURL: collectionURL
                )
            }
            throw error
        }
    }

    private func rollbackNewStaging(
        named stagingName: String,
        expectedIdentity: FileSystemObjectIdentity?,
        collectionDescriptor: Int32,
        stagingURL: URL,
        collectionURL: URL
    ) throws {
        var information = stat()
        let inspectStatus = stagingName.withCString {
            Darwin.fstatat(
                collectionDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectStatus == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              expectedIdentity == nil
                || FileSystemObjectIdentity(from: information)
                    == expectedIdentity else {
            throw ProjectStorageCleanupPreparationError
                .sourceIdentityChanged(stagingURL.path)
        }
        let removeStatus = stagingName.withCString {
            Darwin.unlinkat(collectionDescriptor, $0, AT_REMOVEDIR)
        }
        guard removeStatus == 0 else {
            throw ProjectStorageCleanupPreparationError.systemFailure(
                path: stagingURL.path,
                operation: "rollback new storage cleanup staging",
                code: errno
            )
        }
        try syncDirectory(
            collectionDescriptor,
            path: collectionURL.path,
            operation: "fsync new storage cleanup staging rollback"
        )
    }

    private func rollbackStaging(
        named stagingName: String,
        payloadNames: [String],
        expectedIdentity: FileSystemObjectIdentity,
        stagingDescriptor: Int32,
        collectionDescriptor: Int32,
        stagingURL: URL,
        collectionURL: URL
    ) throws {
        var currentInformation = stat()
        let inspectStatus = stagingName.withCString {
            Darwin.fstatat(
                collectionDescriptor,
                $0,
                &currentInformation,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectStatus == 0,
              FileSystemObjectIdentity(from: currentInformation)
                == expectedIdentity else {
            throw ProjectStorageCleanupPreparationError
                .sourceIdentityChanged(stagingURL.path)
        }
        for name in payloadNames {
            let status = name.withCString {
                Darwin.unlinkat(stagingDescriptor, $0, 0)
            }
            if status != 0, errno != ENOENT {
                throw ProjectStorageCleanupPreparationError.systemFailure(
                    path: stagingURL.appendingPathComponent(name).path,
                    operation: "rollback storage cleanup payload",
                    code: errno
                )
            }
        }
        let removeStatus = stagingName.withCString {
            Darwin.unlinkat(collectionDescriptor, $0, AT_REMOVEDIR)
        }
        guard removeStatus == 0 else {
            throw ProjectStorageCleanupPreparationError.systemFailure(
                path: stagingURL.path,
                operation: "rollback storage cleanup staging",
                code: errno
            )
        }
        try syncDirectory(
            collectionDescriptor,
            path: collectionURL.path,
            operation: "fsync storage cleanup rollback"
        )
    }

    private func openOrCreateDirectory(
        named name: String,
        parentDescriptor: Int32,
        parentURL: URL,
        mode: mode_t,
        requiresPrivatePermissions: Bool
    ) throws -> Int32 {
        let status = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, mode)
        }
        let created = status == 0
        if status != 0, errno != EEXIST {
            throw ProjectStorageCleanupPreparationError.systemFailure(
                path: parentURL.appendingPathComponent(name).path,
                operation: "create storage cleanup operation history",
                code: errno
            )
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ProjectStorageCleanupPreparationError.unsafeSource(
                parentURL.appendingPathComponent(name).path
            )
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == Darwin.geteuid(),
              information.st_nlink >= 2,
              information.st_mode & 0o700 == 0o700,
              information.st_mode & 0o022 == 0,
              !requiresPrivatePermissions
                || information.st_mode & 0o777 == 0o700 else {
            Darwin.close(descriptor)
            throw ProjectStorageCleanupPreparationError.unsafeSource(
                parentURL.appendingPathComponent(name).path
            )
        }
        if created {
            do {
                try syncDirectory(
                    parentDescriptor,
                    path: parentURL.path,
                    operation:
                        "fsync storage cleanup operation-history directory"
                )
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    private func openRelativeDirectory(
        _ relativePath: String,
        projectDescriptor: Int32,
        projectURL: URL
    ) throws -> Int32 {
        let components = relativeComponents(relativePath)
        guard !components.isEmpty else {
            throw ProjectStorageCleanupPreparationError
                .unsafeSource(relativePath)
        }
        let duplicate = Darwin.dup(projectDescriptor)
        guard duplicate >= 0 else {
            throw ProjectStorageCleanupPreparationError.systemFailure(
                path: projectURL.path,
                operation: "duplicate project descriptor",
                code: errno
            )
        }
        var descriptor = duplicate
        do {
            for component in components {
                let next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw ProjectStorageCleanupPreparationError
                        .unsafeSource(relativePath)
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func directoryEntryNames(
        descriptor: Int32,
        displayURL: URL
    ) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0,
              let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(displayURL.path)
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard isSinglePathComponent(name) else {
                throw ProjectStorageCleanupPreparationError
                    .unsafeInventoryEntry(
                        displayURL.appendingPathComponent(name).path
                    )
            }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else {
            throw ProjectStorageCleanupPreparationError
                .unsafeInventoryEntry(displayURL.path)
        }
        return names.sorted()
    }

    private func attestationMap(
        _ inventories: [ProjectStorageCleanupAttestedInventory],
        selectedEntries: [ProjectStorageEntry],
        project: URL
    ) throws
        -> [String: [String: ProjectStorageCleanupInventoryEntry]]
    {
        let selected = Set(selectedEntries.map(\.relativePath))
        var result:
            [String: [String: ProjectStorageCleanupInventoryEntry]] = [:]
        for inventory in inventories {
            guard selected.contains(inventory.sourceRelativePath),
                  result[inventory.sourceRelativePath] == nil,
                  isSingleAbsolutePath(inventory.sourceProvenancePath),
                  isSHA256(inventory.sourceProvenanceChecksumSHA256),
                  let selectedEntry = selectedEntries.first(where: {
                      $0.relativePath == inventory.sourceRelativePath
                  }),
                  selectedEntry.identity == inventory.sourceIdentity else {
                throw ProjectStorageCleanupPreparationError
                    .invalidAttestation(inventory.sourceRelativePath)
            }
            let sourceProvenance = try readAttestationProvenance(
                inventory
            )
            var entries:
                [String: ProjectStorageCleanupInventoryEntry] = [:]
            for entry in inventory.entries {
                guard relativeComponents(entry.relativePath).joined(
                    separator: "/"
                ) == entry.relativePath,
                    entries[entry.relativePath] == nil,
                    isSHA256(entry.sha256) else {
                    throw ProjectStorageCleanupPreparationError
                        .invalidAttestation(entry.relativePath)
                }
                let expectedPath = project.appendingPathComponent(
                    inventory.sourceRelativePath,
                    isDirectory: true
                ).appendingPathComponent(entry.relativePath)
                    .standardizedFileURL.path
                let matches = sourceProvenance.descriptors.filter {
                    $0.path == expectedPath
                }
                guard !matches.isEmpty,
                      matches.allSatisfy({
                          $0.checksumSHA256?.lowercased()
                            == entry.sha256.lowercased()
                              && $0.fileSize == entry.logicalSize
                      }) else {
                    throw ProjectStorageCleanupPreparationError
                        .invalidAttestation(entry.relativePath)
                }
                entries[entry.relativePath] = entry
            }
            result[inventory.sourceRelativePath] = entries
        }
        return result
    }

    private func readAttestationProvenance(
        _ inventory: ProjectStorageCleanupAttestedInventory
    ) throws -> (descriptors: [ProvenanceFileDescriptor], data: Data) {
        let url = URL(
            fileURLWithPath: inventory.sourceProvenancePath
        ).standardizedFileURL
        let parent: Int32
        do {
            parent = try NoFollowFileSystem.openDirectoryHierarchy(
                url.deletingLastPathComponent()
            )
        } catch {
            throw ProjectStorageCleanupPreparationError
                .invalidAttestation(inventory.sourceProvenancePath)
        }
        defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ProjectStorageCleanupPreparationError
                .invalidAttestation(inventory.sourceProvenancePath)
        }
        defer { Darwin.close(descriptor) }
        var beforeInformation = stat()
        let maximumBytes: UInt64 = 64 * 1_024 * 1_024
        guard Darwin.fstat(descriptor, &beforeInformation) == 0,
              beforeInformation.st_mode & S_IFMT == S_IFREG,
              beforeInformation.st_size >= 0,
              UInt64(beforeInformation.st_size) <= maximumBytes,
              UInt64(beforeInformation.st_size)
                == inventory.sourceProvenanceFileSize else {
            throw ProjectStorageCleanupPreparationError
                .invalidAttestation(inventory.sourceProvenancePath)
        }
        let before = FileSnapshot(beforeInformation)
        var data = Data()
        data.reserveCapacity(Int(before.logicalSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try operations.cancellationCheck()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProjectStorageCleanupPreparationError
                    .invalidAttestation(inventory.sourceProvenancePath)
            }
            if count == 0 { break }
            guard data.count <= Int(maximumBytes) - count else {
                throw ProjectStorageCleanupPreparationError
                    .invalidAttestation(inventory.sourceProvenancePath)
            }
            data.append(buffer, count: count)
        }
        operations.didReadAttestationProvenance(
            inventory.sourceProvenancePath
        )
        var afterInformation = stat()
        guard data.count == Int(before.logicalSize),
              Darwin.fstat(descriptor, &afterInformation) == 0,
              FileSnapshot(afterInformation) == before,
              try FileSystemObjectIdentity.noFollow(url)
                == before.identity,
              sha256(data)
                == inventory.sourceProvenanceChecksumSHA256.lowercased()
        else {
            throw ProjectStorageCleanupPreparationError
                .invalidAttestation(inventory.sourceProvenancePath)
        }
        let envelope: ProvenanceEnvelope
        do {
            envelope = try ProvenanceEnvelopeReader.decodeCanonical(data)
        } catch {
            throw ProjectStorageCleanupPreparationError
                .invalidAttestation(inventory.sourceProvenancePath)
        }
        var descriptors = envelope.files + envelope.outputs
        if let output = envelope.output {
            descriptors.append(output)
        }
        return (descriptors, data)
    }

    private func rejectOverlappingSelections(
        _ selected: [ProjectStorageEntry]
    ) throws {
        let selectedPaths = Set(selected.map(\.relativePath))
        for entry in selected {
            let components = relativeComponents(entry.relativePath)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                let ancestor = components.prefix(count)
                    .joined(separator: "/")
                if selectedPaths.contains(ancestor) {
                    throw ProjectStorageCleanupPreparationError
                        .overlappingSelection(
                            ancestor,
                            entry.relativePath
                        )
                }
            }
        }
    }

    private func mergedOptions(
        _ supplied: ProvenanceOptions,
        project: URL,
        selected: [ProjectStorageEntry],
        inventory: ParameterValue
    ) -> ProvenanceOptions {
        var explicit = supplied.explicit
        explicit["projectRoot"] = .string(project.path)
        explicit["selectedPaths"] = .array(
            selected.map { .string($0.relativePath) }
        )
        explicit["intendedAction"] = .string(
            ProjectStorageCleanupJournal.IntendedAction
                .moveToTrash.rawValue
        )
        var resolved = supplied.resolvedDefaults
        resolved["cleanupInventory"] = inventory
        resolved["hashAlgorithm"] = .string("sha256")
        resolved["permanentDeleteFallback"] = .boolean(false)
        return ProvenanceOptions(
            explicit: explicit,
            defaults: supplied.defaults,
            resolvedDefaults: resolved
        )
    }

    private func classificationDigest(
        _ entry: ProjectStorageEntry
    ) throws -> String {
        let evidence = ClassificationEvidence(
            relativePath: entry.relativePath,
            identity: entry.identity,
            category: entry.category.rawValue,
            logicalBytes: entry.logicalBytes,
            allocatedBytes: entry.allocatedBytes,
            disposition: entry.classification.disposition.rawValue,
            code: entry.classification.code.rawValue,
            reason: entry.classification.reason
        )
        return sha256(try canonicalEncoder().encode(evidence))
    }

    private func aggregateDigest(
        _ inventory: [ProjectStorageCleanupInventoryEntry]
    ) throws -> String {
        sha256(try canonicalEncoder().encode(inventory))
    }

    private func stableItemID(
        cleanupID: UUID,
        relativePath: String
    ) -> UUID {
        let bytes = Array(
            SHA256.hash(
                data: Data(
                    "\(cleanupID.uuidString)\u{0}\(relativePath)".utf8
                )
            ).prefix(16)
        )
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], (bytes[6] & 0x0f) | 0x50, bytes[7],
            (bytes[8] & 0x3f) | 0x80, bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func operationDirectoryURL(
        projectURL: URL,
        cleanupID: UUID
    ) -> URL {
        projectURL
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                Self.collectionDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                cleanupID.uuidString.lowercased(),
                isDirectory: true
            )
    }

    private func syncDirectory(
        _ descriptor: Int32,
        path: String,
        operation: String
    ) throws {
        guard operations.syncDirectory(descriptor) == 0 else {
            throw ProjectStorageCleanupPreparationError.systemFailure(
                path: path,
                operation: operation,
                code: errno
            )
        }
    }

    private func relativeComponents(_ path: String) -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return []
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.allSatisfy(isSinglePathComponent) else {
            return []
        }
        return components
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.utf8.contains(0)
    }

    private func isSingleAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && !value.utf8.contains(0)
            && URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    private func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                    .contains($0)
            }
    }
}

private func shellEscapeForCleanup(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let safe = CharacterSet(
        charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            + "_@%+=:,./-"
    )
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
