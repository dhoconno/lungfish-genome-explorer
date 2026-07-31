import CryptoKit
import Darwin
import Foundation
import LungfishIO

enum ProjectStorageCleanupInventoryVerifierError:
    Error,
    LocalizedError
{
    case unsafeProject(String)
    case unsafeSource(String)
    case unsafeInventoryEntry(String)
    case sourceChanged(String)
    case systemFailure(path: String, operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeProject(let path):
            return "Cleanup verification project is unsafe: \(path)"
        case .unsafeSource(let path):
            return "Cleanup verification source is unsafe: \(path)"
        case .unsafeInventoryEntry(let path):
            return "Cleanup verification inventory entry is unsafe: \(path)"
        case .sourceChanged(let path):
            return "Cleanup verification source changed: \(path)"
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}

/// Rebuilds the Task 5 inventory from descriptor-bound, no-follow reads.
///
/// This verifier deliberately has no mutation APIs. A caller must run it
/// under the project cleanup lock immediately before detaching the source.
enum ProjectStorageCleanupInventoryVerifier {
    private struct FileSnapshot: Equatable {
        let identity: FileSystemObjectIdentity
        let logicalSize: UInt64
        let allocatedSize: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init?(_ information: stat) {
            guard information.st_mode & S_IFMT == S_IFREG,
                  information.st_size >= 0,
                  information.st_blocks >= 0 else {
                return nil
            }
            let blocks = UInt64(information.st_blocks)
            guard blocks <= UInt64.max / 512 else { return nil }
            identity = FileSystemObjectIdentity(from: information)
            logicalSize = UInt64(information.st_size)
            allocatedSize = blocks * 512
            modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
            modifiedNanoseconds =
                Int64(information.st_mtimespec.tv_nsec)
            changedSeconds = Int64(information.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(information.st_ctimespec.tv_nsec)
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

        init?(_ information: stat) {
            guard information.st_mode & S_IFMT == S_IFDIR else {
                return nil
            }
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

    static func verify(
        item: ProjectStorageCleanupJournal.Item,
        projectURL: URL,
        scan: ProjectStorageScanResult
    ) throws -> Bool {
        let project = projectURL.standardizedFileURL
        guard let current = scan.entries.first(where: {
            $0.relativePath == item.sourceRelativePath
        }),
        current.identity == item.sourceIdentity,
        current.category == item.sourceCategory,
        current.classification == item.classification,
        current.classification.isRemovable,
        try classificationDigest(current)
            == item.classificationEvidenceDigest else {
            return false
        }

        let projectDescriptor: Int32
        do {
            projectDescriptor =
                try NoFollowFileSystem.openDirectoryHierarchy(project)
        } catch {
            throw ProjectStorageCleanupInventoryVerifierError
                .unsafeProject(project.path)
        }
        defer { Darwin.close(projectDescriptor) }
        var projectInformation = stat()
        guard Darwin.fstat(projectDescriptor, &projectInformation) == 0,
              projectInformation.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(from: projectInformation)
                == scan.projectIdentity else {
            throw ProjectStorageCleanupInventoryVerifierError
                .unsafeProject(project.path)
        }

        let sourceDescriptor = try openRelativeDirectory(
            item.sourceRelativePath,
            projectDescriptor: projectDescriptor,
            projectURL: project
        )
        defer { Darwin.close(sourceDescriptor) }
        var sourceBeforeInformation = stat()
        guard Darwin.fstat(
            sourceDescriptor,
            &sourceBeforeInformation
        ) == 0,
        let sourceBefore = DirectorySnapshot(sourceBeforeInformation),
        sourceBefore.identity == item.sourceIdentity else {
            return false
        }

        var inventory: [ProjectStorageCleanupInventoryEntry] = []
        try inventoryDirectory(
            descriptor: sourceDescriptor,
            displayURL: project.appendingPathComponent(
                item.sourceRelativePath,
                isDirectory: true
            ),
            relativePrefix: "",
            inventory: &inventory
        )
        inventory.sort { $0.relativePath < $1.relativePath }

        var sourceAfterInformation = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceAfterInformation) == 0,
              DirectorySnapshot(sourceAfterInformation) == sourceBefore,
              inventory == item.inventory,
              try aggregateDigest(inventory) == item.aggregateTreeDigest,
              try FileSystemObjectIdentity.noFollow(
                  project.appendingPathComponent(item.sourceRelativePath)
              ) == item.sourceIdentity else {
            return false
        }
        return true
    }

    private static func inventoryDirectory(
        descriptor: Int32,
        displayURL: URL,
        relativePrefix: String,
        inventory: inout [ProjectStorageCleanupInventoryEntry]
    ) throws {
        var beforeInformation = stat()
        guard Darwin.fstat(descriptor, &beforeInformation) == 0,
              let before = DirectorySnapshot(beforeInformation) else {
            throw ProjectStorageCleanupInventoryVerifierError
                .unsafeInventoryEntry(displayURL.path)
        }

        for name in try directoryEntryNames(
            descriptor: descriptor,
            displayURL: displayURL
        ) {
            let relativePath = relativePrefix.isEmpty
                ? name
                : relativePrefix + "/" + name
            var inspectedInformation = stat()
            let status = name.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &inspectedInformation,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard status == 0 else {
                throw ProjectStorageCleanupInventoryVerifierError
                    .unsafeInventoryEntry(
                        displayURL.appendingPathComponent(name).path
                    )
            }
            switch inspectedInformation.st_mode & S_IFMT {
            case S_IFDIR:
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw ProjectStorageCleanupInventoryVerifierError
                        .unsafeInventoryEntry(
                            displayURL.appendingPathComponent(name).path
                        )
                }
                do {
                    var openedInformation = stat()
                    guard Darwin.fstat(child, &openedInformation) == 0,
                          FileSystemObjectIdentity(
                              from: openedInformation
                          ) == FileSystemObjectIdentity(
                              from: inspectedInformation
                          ) else {
                        throw ProjectStorageCleanupInventoryVerifierError
                            .sourceChanged(relativePath)
                    }
                    try inventoryDirectory(
                        descriptor: child,
                        displayURL: displayURL.appendingPathComponent(
                            name,
                            isDirectory: true
                        ),
                        relativePrefix: relativePath,
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
                        relativePath: relativePath,
                        inspectedInformation: inspectedInformation
                    )
                )
            default:
                throw ProjectStorageCleanupInventoryVerifierError
                    .unsafeInventoryEntry(
                        displayURL.appendingPathComponent(name).path
                    )
            }
        }

        var afterInformation = stat()
        guard Darwin.fstat(descriptor, &afterInformation) == 0,
              DirectorySnapshot(afterInformation) == before else {
            throw ProjectStorageCleanupInventoryVerifierError
                .sourceChanged(displayURL.path)
        }
    }

    private static func inventoryFile(
        named name: String,
        directoryDescriptor: Int32,
        displayURL: URL,
        relativePath: String,
        inspectedInformation: stat
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
            throw ProjectStorageCleanupInventoryVerifierError
                .unsafeInventoryEntry(fileURL.path)
        }
        defer { Darwin.close(descriptor) }
        var beforeInformation = stat()
        guard Darwin.fstat(descriptor, &beforeInformation) == 0,
              let before = FileSnapshot(beforeInformation),
              before.identity == FileSystemObjectIdentity(
                  from: inspectedInformation
              ) else {
            throw ProjectStorageCleanupInventoryVerifierError
                .sourceChanged(relativePath)
        }
        let checksum = try hash(
            descriptor: descriptor,
            displayPath: fileURL.path
        )
        var afterInformation = stat()
        guard Darwin.fstat(descriptor, &afterInformation) == 0,
              FileSnapshot(afterInformation) == before else {
            throw ProjectStorageCleanupInventoryVerifierError
                .sourceChanged(relativePath)
        }
        return .init(
            relativePath: relativePath,
            logicalSize: before.logicalSize,
            allocatedSize: before.allocatedSize,
            sha256: checksum,
            device: before.identity.device,
            inode: before.identity.inode,
            modifiedSeconds: before.modifiedSeconds,
            modifiedNanoseconds: before.modifiedNanoseconds,
            changedSeconds: before.changedSeconds,
            changedNanoseconds: before.changedNanoseconds
        )
    }

    private static func openRelativeDirectory(
        _ relativePath: String,
        projectDescriptor: Int32,
        projectURL: URL
    ) throws -> Int32 {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy(isSinglePathComponent) else {
            throw ProjectStorageCleanupInventoryVerifierError
                .unsafeSource(relativePath)
        }
        var descriptor = Darwin.dup(projectDescriptor)
        guard descriptor >= 0 else {
            throw ProjectStorageCleanupInventoryVerifierError
                .systemFailure(
                    path: projectURL.path,
                    operation: "duplicate project descriptor",
                    code: errno
                )
        }
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
                    throw ProjectStorageCleanupInventoryVerifierError
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

    private static func directoryEntryNames(
        descriptor: Int32,
        displayURL: URL
    ) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0,
              let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw ProjectStorageCleanupInventoryVerifierError
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
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard isSinglePathComponent(name) else {
                throw ProjectStorageCleanupInventoryVerifierError
                    .unsafeInventoryEntry(
                        displayURL.appendingPathComponent(name).path
                    )
            }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else {
            throw ProjectStorageCleanupInventoryVerifierError
                .unsafeInventoryEntry(displayURL.path)
        }
        return names.sorted()
    }

    private static func hash(
        descriptor: Int32,
        displayPath: String
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProjectStorageCleanupInventoryVerifierError
                    .systemFailure(
                        path: displayPath,
                        operation: "hash cleanup inventory file",
                        code: errno
                    )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func classificationDigest(
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

    private static func aggregateDigest(
        _ inventory: [ProjectStorageCleanupInventoryEntry]
    ) throws -> String {
        sha256(try canonicalEncoder().encode(inventory))
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSinglePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.utf8.contains(0)
    }
}
