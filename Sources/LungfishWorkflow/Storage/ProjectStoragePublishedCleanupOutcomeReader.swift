import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum ProjectStoragePublishedCleanupOutcomeError:
    Error,
    LocalizedError,
    Equatable
{
    case missingCompleteReceipt
    case unsafeAuthority(String)
    case mismatchedReceipt

    public var errorDescription: String? {
        switch self {
        case .missingCompleteReceipt:
            return "No complete published cleanup receipt pair was found."
        case .unsafeAuthority(let path):
            return "The published cleanup receipt authority is unsafe: \(path)"
        case .mismatchedReceipt:
            return "The published cleanup summary and provenance do not match."
        }
    }
}

public struct ProjectStoragePublishedCleanupOutcomeReader: Sendable {
    enum FileRole: Sendable {
        case summary
        case provenance
    }

    struct Operations: Sendable {
        var afterOpenOperationDirectory: @Sendable () throws -> Void
        var afterFirstReadChunk: @Sendable (FileRole) throws -> Void

        init(
            afterOpenOperationDirectory:
                @escaping @Sendable () throws -> Void = {},
            afterFirstReadChunk:
                @escaping @Sendable (FileRole) throws -> Void = { _ in }
        ) {
            self.afterOpenOperationDirectory = afterOpenOperationDirectory
            self.afterFirstReadChunk = afterFirstReadChunk
        }
    }

    private struct DirectorySnapshot: Equatable {
        let identity: FileSystemObjectIdentity
        let mode: UInt64
        let linkCount: UInt64
        let size: Int64
        let blocks: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ information: stat) {
            identity = FileSystemObjectIdentity(from: information)
            mode = UInt64(information.st_mode)
            linkCount = UInt64(information.st_nlink)
            size = information.st_size
            blocks = information.st_blocks
            modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(information.st_mtimespec.tv_nsec)
            changedSeconds = Int64(information.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(information.st_ctimespec.tv_nsec)
        }
    }

    private struct FileSnapshot: Equatable {
        let identity: FileSystemObjectIdentity
        let mode: UInt64
        let linkCount: UInt64
        let owner: UInt64
        let group: UInt64
        let size: UInt64
        let blocks: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let flags: UInt64
        let generation: UInt64

        init?(_ information: stat) {
            guard information.st_size >= 0 else { return nil }
            identity = FileSystemObjectIdentity(from: information)
            mode = UInt64(information.st_mode)
            linkCount = UInt64(information.st_nlink)
            owner = UInt64(information.st_uid)
            group = UInt64(information.st_gid)
            size = UInt64(information.st_size)
            blocks = information.st_blocks
            modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(information.st_mtimespec.tv_nsec)
            changedSeconds = Int64(information.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(information.st_ctimespec.tv_nsec)
            birthSeconds = Int64(information.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(information.st_birthtimespec.tv_nsec)
            flags = UInt64(information.st_flags)
            generation = UInt64(information.st_gen)
        }
    }

    private struct StableFile {
        let data: Data
        let snapshot: FileSnapshot
    }

    private struct ReceiptPair {
        let summaryName: String
        let provenanceName: String
    }

    /// A 256 MiB per-file ceiling accommodates the planned 65,536-entry
    /// cleanup inventory while bounding allocation if an operation directory
    /// is corrupted or hostile.
    private static let maximumReceiptBytes: UInt64 =
        256 * 1_024 * 1_024
    private static let maximumDirectoryEntries = 131_072

    private let operations: Operations

    public init() {
        operations = .init()
    }

    init(operations: Operations) {
        self.operations = operations
    }

    public func readLatest(
        from preparation: ProjectStorageCleanupPreparation
    ) throws -> ProjectStorageCleanupExecutionResult {
        try readLatest(
            operationDirectoryURL: preparation.operationDirectoryURL,
            expectedOperationDirectoryIdentity:
                preparation.operationDirectoryIdentity,
            cleanupID: preparation.journal.cleanupID
        )
    }

    public func readLatest(
        operationDirectoryURL: URL,
        expectedOperationDirectoryIdentity:
            FileSystemObjectIdentity,
        cleanupID: UUID
    ) throws -> ProjectStorageCleanupExecutionResult {
        let operationURL = operationDirectoryURL.standardizedFileURL
        let directory = try openExpectedOperationDirectory(
            operationURL,
            expectedIdentity: expectedOperationDirectoryIdentity
        )
        defer { Darwin.close(directory) }
        let directoryBefore = try snapshotDirectory(
            directory,
            displayURL: operationURL
        )
        try operations.afterOpenOperationDirectory()

        let pair = try latestPair(
            in: directory,
            displayURL: operationURL
        )
        let summary = try readStableRegularFile(
            named: pair.summaryName,
            role: .summary,
            in: directory,
            displayURL: operationURL
        )
        let provenance = try readStableRegularFile(
            named: pair.provenanceName,
            role: .provenance,
            in: directory,
            displayURL: operationURL
        )
        try requireNamedFile(
            pair.summaryName,
            snapshot: summary.snapshot,
            in: directory,
            displayURL: operationURL
        )
        try requireNamedFile(
            pair.provenanceName,
            snapshot: provenance.snapshot,
            in: directory,
            displayURL: operationURL
        )
        let directoryAfter = try snapshotDirectory(
            directory,
            displayURL: operationURL
        )
        guard directoryAfter == directoryBefore else {
            throw unsafe(operationURL)
        }
        try validateOperationPathAfterRead(
            operationURL,
            expectedIdentity: expectedOperationDirectoryIdentity
        )

        let summaryURL = operationURL.appendingPathComponent(
            pair.summaryName
        )
        let provenanceURL = operationURL.appendingPathComponent(
            pair.provenanceName
        )
        let decodedSummary: ProjectStorageCleanupExecutionSummary
        let decodedProvenance: ProvenanceEnvelope
        do {
            decodedSummary = try ProvenanceJSON.decoder.decode(
                ProjectStorageCleanupExecutionSummary.self,
                from: summary.data
            )
            decodedProvenance =
                try ProvenanceEnvelopeReader.decodeCanonical(
                    provenance.data
                )
        } catch {
            throw ProjectStoragePublishedCleanupOutcomeError
                .mismatchedReceipt
        }
        let itemIDs = decodedSummary.items.map(\.itemID)
        let checksum = SHA256.hash(data: summary.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let matchingSummaryOutputs = decodedProvenance.outputs.filter {
            $0.path == summaryURL.path
        }
        guard decodedSummary.cleanupID == cleanupID,
              decodedProvenance.id == cleanupID,
              Set(itemIDs).count == itemIDs.count,
              matchingSummaryOutputs.count == 1,
              let descriptor = matchingSummaryOutputs.first,
              descriptor.role == .output,
              descriptor.format == .json,
              descriptor.checksumSHA256?.lowercased() == checksum,
              descriptor.fileSize == UInt64(summary.data.count) else {
            throw ProjectStoragePublishedCleanupOutcomeError
                .mismatchedReceipt
        }
        return .init(
            summary: decodedSummary,
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
    }

    private func openExpectedOperationDirectory(
        _ url: URL,
        expectedIdentity: FileSystemObjectIdentity
    ) throws -> Int32 {
        let descriptor: Int32
        do {
            descriptor = try NoFollowFileSystem.openDirectoryHierarchy(url)
        } catch {
            throw unsafe(url)
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(from: information)
                == expectedIdentity else {
            Darwin.close(descriptor)
            throw unsafe(url)
        }
        return descriptor
    }

    private func validateOperationPathAfterRead(
        _ url: URL,
        expectedIdentity: FileSystemObjectIdentity
    ) throws {
        let descriptor = try openExpectedOperationDirectory(
            url,
            expectedIdentity: expectedIdentity
        )
        Darwin.close(descriptor)
    }

    private func snapshotDirectory(
        _ descriptor: Int32,
        displayURL: URL
    ) throws -> DirectorySnapshot {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw unsafe(displayURL)
        }
        return DirectorySnapshot(information)
    }

    private func latestPair(
        in directory: Int32,
        displayURL: URL
    ) throws -> ReceiptPair {
        let names = try directoryEntryNames(
            descriptor: directory,
            displayURL: displayURL
        )
        let summaryPrefix = "execution-summary-"
        let provenancePrefix = "execution-provenance-"
        let suffix = ".json"
        let summarySequences = Set(names.compactMap {
            sequence(
                in: $0,
                prefix: summaryPrefix,
                suffix: suffix
            )
        })
        let provenanceSequences = Set(names.compactMap {
            sequence(
                in: $0,
                prefix: provenancePrefix,
                suffix: suffix
            )
        })
        guard let sequence = summarySequences
            .intersection(provenanceSequences)
            .sorted()
            .last else {
            throw ProjectStoragePublishedCleanupOutcomeError
                .missingCompleteReceipt
        }
        return ReceiptPair(
            summaryName: summaryPrefix + sequence + suffix,
            provenanceName: provenancePrefix + sequence + suffix
        )
    }

    private func sequence(
        in name: String,
        prefix: String,
        suffix: String
    ) -> String? {
        guard name.hasPrefix(prefix),
              name.hasSuffix(suffix) else {
            return nil
        }
        let value = String(
            name.dropFirst(prefix.count).dropLast(suffix.count)
        )
        guard value.utf8.count == 8,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        return value
    }

    private func directoryEntryNames(
        descriptor: Int32,
        displayURL: URL
    ) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0,
              let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw unsafe(displayURL)
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
            if name == "." || name == ".." {
                errno = 0
                continue
            }
            guard isSinglePathComponent(name),
                  names.count < Self.maximumDirectoryEntries else {
                throw unsafe(displayURL)
            }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else {
            throw unsafe(displayURL)
        }
        return names.sorted()
    }

    private func readStableRegularFile(
        named name: String,
        role: FileRole,
        in directory: Int32,
        displayURL: URL
    ) throws -> StableFile {
        let fileURL = displayURL.appendingPathComponent(name)
        let entryBefore = try namedFileSnapshot(
            name,
            in: directory,
            displayURL: displayURL
        )
        let descriptor = name.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw unsafe(fileURL)
        }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              let opened = FileSnapshot(openedInformation),
              opened == entryBefore,
              opened.mode & UInt64(S_IFMT) == UInt64(S_IFREG),
              opened.size <= Self.maximumReceiptBytes,
              let expectedCount = Int(exactly: opened.size) else {
            throw unsafe(fileURL)
        }

        var data = Data()
        data.reserveCapacity(expectedCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var invokedReadHook = false
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw unsafe(fileURL)
            }
            if count == 0 { break }
            guard count <= expectedCount - data.count else {
                throw unsafe(fileURL)
            }
            data.append(buffer, count: count)
            if !invokedReadHook {
                invokedReadHook = true
                try operations.afterFirstReadChunk(role)
            }
        }
        var descriptorAfterInformation = stat()
        guard data.count == expectedCount,
              Darwin.fstat(
                descriptor,
                &descriptorAfterInformation
              ) == 0,
              let descriptorAfter =
                FileSnapshot(descriptorAfterInformation),
              descriptorAfter == opened else {
            throw unsafe(fileURL)
        }
        try requireNamedFile(
            name,
            snapshot: opened,
            in: directory,
            displayURL: displayURL
        )
        return StableFile(data: data, snapshot: opened)
    }

    private func requireNamedFile(
        _ name: String,
        snapshot: FileSnapshot,
        in directory: Int32,
        displayURL: URL
    ) throws {
        guard try namedFileSnapshot(
            name,
            in: directory,
            displayURL: displayURL
        ) == snapshot else {
            throw unsafe(displayURL.appendingPathComponent(name))
        }
    }

    private func namedFileSnapshot(
        _ name: String,
        in directory: Int32,
        displayURL: URL
    ) throws -> FileSnapshot {
        var information = stat()
        let status = name.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0,
              information.st_mode & S_IFMT == S_IFREG,
              let snapshot = FileSnapshot(information) else {
            throw unsafe(displayURL.appendingPathComponent(name))
        }
        return snapshot
    }

    private func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }

    private func unsafe(
        _ url: URL
    ) -> ProjectStoragePublishedCleanupOutcomeError {
        .unsafeAuthority(url.path)
    }
}
