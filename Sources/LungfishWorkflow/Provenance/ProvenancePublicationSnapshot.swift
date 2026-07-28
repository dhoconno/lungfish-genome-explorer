// ProvenancePublicationSnapshot.swift - rollback support for provenance-gated payload writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

public enum ProvenancePublicationSnapshotError:
    Error, LocalizedError, Sendable
{
    case invalidRollbackWitness
    case artifactInspectionFailed(path: String, code: Int32)
    case artifactChangedDuringSnapshot(path: String)
    case mutationReceiptConflict(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRollbackWitness:
            return "The provenance rollback witness belongs to a different publication snapshot."
        case .artifactInspectionFailed(let path, let code):
            return "Could not inspect provenance publication artifact at "
                + "\(path) (errno \(code))."
        case .artifactChangedDuringSnapshot(let path):
            return "The provenance publication artifact changed while its rollback snapshot was captured: \(path)."
        case .mutationReceiptConflict(let path):
            return "The provenance publication artifact no longer matches the transaction generation at \(path)."
        }
    }
}

struct ProvenancePublicationArtifactMetadata:
    Equatable, Sendable
{
    let mode: UInt32
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt64
    let size: Int64
}

indirect enum ProvenancePublicationArtifactState:
    Equatable, Sendable
{
    case missing
    case file(
        ProvenancePublicationArtifactMetadata,
        sha256: String
    )
    case symbolicLink(
        ProvenancePublicationArtifactMetadata,
        destination: String
    )
    case directory(
        ProvenancePublicationArtifactMetadata,
        children: [ProvenancePublicationDirectoryEntry]
    )
    case other(ProvenancePublicationArtifactMetadata)
}

struct ProvenancePublicationDirectoryEntry:
    Equatable, Sendable
{
    let name: String
    let state: ProvenancePublicationArtifactState
}

/// Filesystem identities captured after this transaction publishes its
/// payload. A rollback may restore only artifacts that still match these
/// identities; another writer's later replacement is therefore preserved.
public struct ProvenancePublicationRollbackWitness: Sendable {
    fileprivate let snapshotID: UUID
    fileprivate let states: [String: ProvenancePublicationArtifactState]
}

/// Captures payload and provenance artifacts before a workflow publishes new
/// scientific data. Restore the snapshot if provenance publication fails.
public struct ProvenancePublicationSnapshot {
    private struct Entry {
        let originalURL: URL
        let backupURL: URL?
        let initialState: ProvenancePublicationArtifactState
    }

    private let fileManager: FileManager
    private let backupDirectory: URL
    private let entries: [Entry]
    private let snapshotID: UUID

    public init(
        urls: [URL],
        backupNamePrefix: String = "lungfish-provenance-publication",
        fileManager: FileManager = .default,
        afterBackupCopy: ((URL) throws -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        snapshotID = UUID()
        backupDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(backupNamePrefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var seen = Set<String>()
        var capturedEntries: [Entry] = []
        do {
            for (index, url) in urls.enumerated() {
                let standardizedURL = url.standardizedFileURL
                guard seen.insert(standardizedURL.path).inserted else {
                    continue
                }
                let stateBeforeCopy = try Self.artifactState(
                    at: standardizedURL,
                    fileManager: fileManager
                )
                guard stateBeforeCopy != .missing else {
                    let stateAfterCheck = try Self.artifactState(
                        at: standardizedURL,
                        fileManager: fileManager
                    )
                    guard stateAfterCheck == .missing else {
                        throw ProvenancePublicationSnapshotError
                            .artifactChangedDuringSnapshot(
                                path: standardizedURL.path
                            )
                    }
                    capturedEntries.append(
                        Entry(
                            originalURL: standardizedURL,
                            backupURL: nil,
                            initialState: .missing
                        )
                    )
                    continue
                }
                let backupURL = backupDirectory.appendingPathComponent(
                    "artifact-\(index)"
                )
                try fileManager.copyItem(at: standardizedURL, to: backupURL)
                try afterBackupCopy?(standardizedURL)
                let stateAfterCopy = try Self.artifactState(
                    at: standardizedURL,
                    fileManager: fileManager
                )
                let backupState = try Self.artifactState(
                    at: backupURL,
                    fileManager: fileManager
                )
                guard Self.statesMatch(stateBeforeCopy, stateAfterCopy),
                      Self.haveEquivalentBackupContent(
                        stateAfterCopy,
                        backupState
                      ) else {
                    throw ProvenancePublicationSnapshotError
                        .artifactChangedDuringSnapshot(
                            path: standardizedURL.path
                        )
                }
                capturedEntries.append(
                    Entry(
                        originalURL: standardizedURL,
                        backupURL: backupURL,
                        initialState: stateAfterCopy
                    )
                )
            }
        } catch {
            try? fileManager.removeItem(at: backupDirectory)
            throw error
        }
        entries = capturedEntries
    }

    /// Captures the exact attempted filesystem state at the transaction's
    /// rollback boundary. Call this after publishing the payload and before
    /// provenance publication can fail.
    public func captureRollbackWitness()
        throws -> ProvenancePublicationRollbackWitness
    {
        var states: [String: ProvenancePublicationArtifactState] = [:]
        for entry in entries {
            states[entry.originalURL.path] = entry.initialState
        }
        return ProvenancePublicationRollbackWitness(
            snapshotID: snapshotID,
            states: states
        )
    }

    /// Publishes a staged protected artifact with an operation-derived
    /// rollback receipt. Any existing destination is first claimed by an
    /// exclusive rename and must match the bound witness before publication
    /// may continue.
    public func publishReplacement(
        from stagedURL: URL,
        to destinationURL: URL,
        replacingExisting: Bool,
        witness: ProvenancePublicationRollbackWitness,
        beforeExistingArtifactClaim: (() throws -> Void)? = nil
    ) throws -> (
        witness: ProvenancePublicationRollbackWitness,
        displacedURL: URL?
    ) {
        guard witness.snapshotID == snapshotID else {
            throw ProvenancePublicationSnapshotError.invalidRollbackWitness
        }
        let destination = destinationURL.standardizedFileURL
        guard entries.contains(where: {
            $0.originalURL.path == destination.path
        }), let expectedPrior = witness.states[destination.path] else {
            throw ProvenancePublicationSnapshotError
                .mutationReceiptConflict(path: destination.path)
        }
        let stagedState = try Self.artifactState(
            at: stagedURL,
            fileManager: fileManager
        )
        guard stagedState != .missing else {
            throw ProvenancePublicationSnapshotError
                .mutationReceiptConflict(path: stagedURL.path)
        }

        var displacedURL: URL?
        if replacingExisting, expectedPrior != .missing {
            try beforeExistingArtifactClaim?()
            let candidate = destination.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destination.lastPathComponent)"
                        + ".provenance-forward-\(UUID().uuidString)"
                )
            let detached = try Self.renameExclusivelyIfPresent(
                from: destination,
                to: candidate
            )
            guard detached else {
                throw ProvenancePublicationSnapshotError
                    .mutationReceiptConflict(path: destination.path)
            }
            let detachedState: ProvenancePublicationArtifactState
            do {
                detachedState = try Self.artifactState(
                    at: candidate,
                    fileManager: fileManager
                )
            } catch {
                try Self.restoreDisplacedArtifact(
                    candidate,
                    to: destination,
                    originalError: error
                )
                throw error
            }
            guard Self.statesMatch(detachedState, expectedPrior) else {
                try Self.restoreDisplacedArtifact(
                    candidate,
                    to: destination,
                    originalError:
                        ProvenancePublicationSnapshotError
                            .mutationReceiptConflict(
                                path: destination.path
                            )
                )
                throw ProvenancePublicationSnapshotError
                    .mutationReceiptConflict(path: destination.path)
            }
            displacedURL = candidate
        } else {
            guard expectedPrior == .missing else {
                throw ProvenancePublicationSnapshotError
                    .mutationReceiptConflict(path: destination.path)
            }
        }

        do {
            let published = try Self.renameExclusivelyIfPresent(
                from: stagedURL,
                to: destination
            )
            guard published else {
                throw ProvenancePublicationSnapshotError
                    .mutationReceiptConflict(path: destination.path)
            }
        } catch {
            if let displacedURL {
                try Self.restoreDisplacedArtifact(
                    displacedURL,
                    to: destination,
                    originalError: error
                )
            }
            throw error
        }

        var updatedStates = witness.states
        updatedStates[destination.path] = stagedState
        return (
            ProvenancePublicationRollbackWitness(
                snapshotID: snapshotID,
                states: updatedStates
            ),
            displacedURL
        )
    }

    /// Applies an operation-derived mutation receipt without re-reading a
    /// public pathname whose ownership may already have changed. The receipt
    /// must bind both the generation claimed by the operation and the exact
    /// resulting generation.
    public func refreshingRollbackWitness(
        _ witness: ProvenancePublicationRollbackWitness,
        after mutation: ProvenanceWriterMutation
    ) throws -> ProvenancePublicationRollbackWitness {
        guard witness.snapshotID == snapshotID else {
            throw ProvenancePublicationSnapshotError.invalidRollbackWitness
        }
        var states = witness.states
        for mutationURL in mutation.affectedURLs.map(\.standardizedFileURL) {
            guard let requiredPrior =
                    mutation.requiredPriorStates[mutationURL.path],
                  let resulting =
                    mutation.resultingStates[mutationURL.path],
                  let protectedEntry = entries.first(where: {
                      mutationURL.path == $0.originalURL.path
                          || Self.relativePathComponents(
                              of: mutationURL,
                              below: $0.originalURL
                          ) != nil
                  }) else {
                throw ProvenancePublicationSnapshotError
                    .mutationReceiptConflict(path: mutationURL.path)
            }
            let rootPath = protectedEntry.originalURL.path
            let rootState = states[rootPath] ?? .missing
            let components = Self.relativePathComponents(
                of: mutationURL,
                below: protectedEntry.originalURL
            ) ?? []
            let witnessedPrior = Self.state(
                in: rootState,
                at: components
            )
            guard Self.statesMatch(witnessedPrior, requiredPrior) else {
                throw ProvenancePublicationSnapshotError
                    .mutationReceiptConflict(path: mutationURL.path)
            }
            states[rootPath] = try Self.replacingState(
                in: rootState,
                at: components,
                with: resulting,
                path: mutationURL.path
            )
        }
        return ProvenancePublicationRollbackWitness(
            snapshotID: snapshotID,
            states: states
        )
    }

    public func restore() throws {
        for entry in entries.reversed() {
            try restore(entry)
        }
    }

    /// Compare-and-restore rollback. Paths changed after the attempted-state
    /// witness was captured are left untouched so a noncooperating writer is
    /// never overwritten by this transaction's stale backup.
    @discardableResult
    public func restore(
        ifCurrentMatches witness: ProvenancePublicationRollbackWitness,
        afterArtifactDetached: ((URL) throws -> Void)? = nil
    ) throws -> [URL] {
        guard witness.snapshotID == snapshotID else {
            throw ProvenancePublicationSnapshotError.invalidRollbackWitness
        }
        var preservedExternalChanges: [URL] = []
        for entry in entries.reversed() {
            guard let attemptedState = witness.states[entry.originalURL.path]
            else {
                preservedExternalChanges.append(entry.originalURL)
                continue
            }
            let preserved = try restoreByAtomicDetachment(
                entry,
                attemptedState: attemptedState,
                afterArtifactDetached: afterArtifactDetached
            )
            preservedExternalChanges.append(contentsOf: preserved)
        }
        return preservedExternalChanges.reversed()
    }

    public func discard() {
        try? fileManager.removeItem(at: backupDirectory)
    }

    private func restore(_ entry: Entry) throws {
        if Self.pathExistsWithoutFollowingSymbolicLinks(entry.originalURL) {
            try fileManager.removeItem(at: entry.originalURL)
        }
        guard let backupURL = entry.backupURL else { return }
        try fileManager.createDirectory(
            at: entry.originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: backupURL, to: entry.originalURL)
    }

    private func restoreByAtomicDetachment(
        _ entry: Entry,
        attemptedState: ProvenancePublicationArtifactState,
        afterArtifactDetached: ((URL) throws -> Void)?
    ) throws -> [URL] {
        let quarantineURL = entry.originalURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(entry.originalURL.lastPathComponent)"
                    + ".provenance-rollback-\(UUID().uuidString)"
            )
        let detached = try Self.renameExclusivelyIfPresent(
            from: entry.originalURL,
            to: quarantineURL
        )
        guard detached else {
            guard attemptedState == .missing else {
                return [entry.originalURL]
            }
            return try restoreBackupExclusively(
                entry,
                displacedURL: nil
            )
        }

        do {
            try afterArtifactDetached?(entry.originalURL)
        } catch {
            _ = try? Self.renameExclusivelyIfPresent(
                from: quarantineURL,
                to: entry.originalURL
            )
            throw error
        }

        let detachedState = try Self.artifactState(
            at: quarantineURL,
            fileManager: fileManager
        )
        guard Self.statesMatch(detachedState, attemptedState) else {
            let restored = try Self.renameExclusivelyIfPresent(
                from: quarantineURL,
                to: entry.originalURL
            )
            if restored {
                return [entry.originalURL]
            }
            // A later writer already recreated the public pathname. Keep the
            // displaced external artifact quarantined rather than deleting
            // either writer's data.
            return [entry.originalURL, quarantineURL]
        }

        return try restoreBackupExclusively(
            entry,
            displacedURL: quarantineURL
        )
    }

    private func restoreBackupExclusively(
        _ entry: Entry,
        displacedURL: URL?
    ) throws -> [URL] {
        var preservedExternalChanges: [URL] = []
        if let backupURL = entry.backupURL {
            let restoreCandidate = entry.originalURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(entry.originalURL.lastPathComponent)"
                        + ".provenance-restore-\(UUID().uuidString)"
                )
            do {
                try fileManager.copyItem(
                    at: backupURL,
                    to: restoreCandidate
                )
                let restored = try Self.renameExclusivelyIfPresent(
                    from: restoreCandidate,
                    to: entry.originalURL
                )
                if !restored {
                    preservedExternalChanges.append(entry.originalURL)
                    try? fileManager.removeItem(at: restoreCandidate)
                }
            } catch {
                try? fileManager.removeItem(at: restoreCandidate)
                throw error
            }
        }
        if let displacedURL,
           Self.pathExistsWithoutFollowingSymbolicLinks(displacedURL) {
            try fileManager.removeItem(at: displacedURL)
        }
        return preservedExternalChanges
    }

    private static func renameExclusivelyIfPresent(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> Bool {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                PortableExclusiveRename.renameatxNP(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == EEXIST {
                return false
            }
            throw ProvenancePublicationSnapshotError
                .artifactInspectionFailed(
                    path: sourceURL.path,
                    code: code
                )
        }
        return true
    }

    private static func restoreDisplacedArtifact(
        _ displacedURL: URL,
        to destinationURL: URL,
        originalError: Error
    ) throws {
        do {
            let restored = try renameExclusivelyIfPresent(
                from: displacedURL,
                to: destinationURL
            )
            guard restored else {
                throw ProvenancePublicationPreservedChangesError(
                    urls: [destinationURL, displacedURL]
                )
            }
        } catch {
            throw ProvenancePublicationRollbackError(
                originalError: originalError,
                rollbackError: error
            )
        }
    }

    static func artifactState(
        at url: URL,
        fileManager: FileManager
    ) throws -> ProvenancePublicationArtifactState {
        var information = stat()
        let status = url.path.withCString {
            Darwin.lstat($0, &information)
        }
        guard status == 0 else {
            let code = errno
            if code == ENOENT {
                return .missing
            }
            throw ProvenancePublicationSnapshotError
                .artifactInspectionFailed(path: url.path, code: code)
        }
        let metadata = artifactMetadata(information)
        switch information.st_mode & S_IFMT {
        case S_IFREG:
            return .file(
                metadata,
                sha256: try regularFileSHA256(
                    at: url,
                    expectedMetadata: metadata
                )
            )
        case S_IFLNK:
            let destination: String
            do {
                destination = try fileManager.destinationOfSymbolicLink(
                    atPath: url.path
                )
            } catch {
                throw ProvenancePublicationSnapshotError
                    .artifactInspectionFailed(path: url.path, code: EIO)
            }
            return .symbolicLink(metadata, destination: destination)
        case S_IFDIR:
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw ProvenancePublicationSnapshotError
                    .artifactInspectionFailed(path: url.path, code: EIO)
            }
            let entries = try children
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map {
                    ProvenancePublicationDirectoryEntry(
                        name: $0.lastPathComponent,
                        state: try artifactState(
                            at: $0,
                            fileManager: fileManager
                        )
                    )
                }
            return .directory(metadata, children: entries)
        default:
            return .other(metadata)
        }
    }

    private static func state(
        in rootState: ProvenancePublicationArtifactState,
        at components: [String]
    ) -> ProvenancePublicationArtifactState {
        guard let component = components.first else {
            return rootState
        }
        guard case .directory(_, let children) = rootState,
              let child = children.first(where: {
                  $0.name == component
              }) else {
            return .missing
        }
        return state(
            in: child.state,
            at: Array(components.dropFirst())
        )
    }

    private static func replacingState(
        in rootState: ProvenancePublicationArtifactState,
        at components: [String],
        with replacement: ProvenancePublicationArtifactState,
        path: String
    ) throws -> ProvenancePublicationArtifactState {
        guard let component = components.first else {
            return replacement
        }
        guard case .directory(let metadata, var children) = rootState else {
            throw ProvenancePublicationSnapshotError
                .mutationReceiptConflict(path: path)
        }
        let existing = children.first(where: {
            $0.name == component
        })?.state ?? .missing
        let replaced = try replacingState(
            in: existing,
            at: Array(components.dropFirst()),
            with: replacement,
            path: path
        )
        children.removeAll { $0.name == component }
        if replaced != .missing {
            children.append(
                ProvenancePublicationDirectoryEntry(
                    name: component,
                    state: replaced
                )
            )
            children.sort { $0.name < $1.name }
        }
        return .directory(metadata, children: children)
    }

    static func statesMatch(
        _ lhs: ProvenancePublicationArtifactState,
        _ rhs: ProvenancePublicationArtifactState
    ) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing):
            return true
        case let (
            .file(leftMetadata, leftDigest),
            .file(rightMetadata, rightDigest)
        ):
            return leftMetadata == rightMetadata
                && leftDigest == rightDigest
        case let (
            .symbolicLink(leftMetadata, leftDestination),
            .symbolicLink(rightMetadata, rightDestination)
        ):
            return leftMetadata == rightMetadata
                && leftDestination == rightDestination
        case let (
            .directory(leftMetadata, leftChildren),
            .directory(rightMetadata, rightChildren)
        ):
            guard leftMetadata.mode == rightMetadata.mode,
                  leftMetadata.device == rightMetadata.device,
                  leftMetadata.inode == rightMetadata.inode,
                  leftChildren.count == rightChildren.count else {
                return false
            }
            return zip(leftChildren, rightChildren).allSatisfy { pair in
                pair.0.name == pair.1.name
                    && statesMatch(pair.0.state, pair.1.state)
            }
        case let (.other(leftMetadata), .other(rightMetadata)):
            return leftMetadata == rightMetadata
        default:
            return false
        }
    }

    private static func haveEquivalentBackupContent(
        _ original: ProvenancePublicationArtifactState,
        _ backup: ProvenancePublicationArtifactState
    ) -> Bool {
        switch (original, backup) {
        case (.missing, .missing):
            return true
        case let (
            .file(leftMetadata, leftDigest),
            .file(rightMetadata, rightDigest)
        ):
            return leftMetadata.size == rightMetadata.size
                && leftDigest == rightDigest
        case let (
            .symbolicLink(_, leftDestination),
            .symbolicLink(_, rightDestination)
        ):
            return leftDestination == rightDestination
        case let (
            .directory(_, leftChildren),
            .directory(_, rightChildren)
        ):
            guard leftChildren.count == rightChildren.count else {
                return false
            }
            return zip(leftChildren, rightChildren).allSatisfy { pair in
                pair.0.name == pair.1.name
                    && haveEquivalentBackupContent(
                        pair.0.state,
                        pair.1.state
                    )
            }
        case let (.other(leftMetadata), .other(rightMetadata)):
            return leftMetadata.mode & UInt32(S_IFMT)
                    == rightMetadata.mode & UInt32(S_IFMT)
                && leftMetadata.size == rightMetadata.size
        default:
            return false
        }
    }

    private static func relativePathComponents(
        of descendantURL: URL,
        below rootURL: URL
    ) -> [String]? {
        let rootPath = rootURL.standardizedFileURL.path
        let descendantPath = descendantURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard descendantPath.hasPrefix(prefix) else { return nil }
        let relativePath = String(descendantPath.dropFirst(prefix.count))
        let components = relativePath.split(separator: "/").map(String.init)
        return components.isEmpty ? nil : components
    }

    private static func artifactMetadata(
        _ information: stat
    ) -> ProvenancePublicationArtifactMetadata {
        ProvenancePublicationArtifactMetadata(
            mode: UInt32(information.st_mode),
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            linkCount: UInt64(information.st_nlink),
            size: Int64(information.st_size)
        )
    }

    private static func pathExistsWithoutFollowingSymbolicLinks(
        _ url: URL
    ) -> Bool {
        var information = stat()
        return url.path.withCString {
            Darwin.lstat($0, &information)
        } == 0
    }

    private static func regularFileSHA256(
        at url: URL,
        expectedMetadata: ProvenancePublicationArtifactMetadata
    ) throws -> String {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ProvenancePublicationSnapshotError.artifactInspectionFailed(
                path: url.path,
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }

        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0 else {
            throw ProvenancePublicationSnapshotError.artifactInspectionFailed(
                path: url.path,
                code: errno
            )
        }
        guard openedInformation.st_mode & S_IFMT == S_IFREG,
              UInt64(openedInformation.st_dev) == expectedMetadata.device,
              UInt64(openedInformation.st_ino) == expectedMetadata.inode,
              Int64(openedInformation.st_size) == expectedMetadata.size else {
            throw ProvenancePublicationSnapshotError.artifactInspectionFailed(
                path: url.path,
                code: EBUSY
            )
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw ProvenancePublicationSnapshotError
                    .artifactInspectionFailed(path: url.path, code: code)
            }
            hasher.update(data: Data(buffer[0..<count]))
        }

        var completedInformation = stat()
        guard Darwin.fstat(descriptor, &completedInformation) == 0 else {
            throw ProvenancePublicationSnapshotError.artifactInspectionFailed(
                path: url.path,
                code: errno
            )
        }
        guard UInt64(completedInformation.st_dev)
                == expectedMetadata.device,
              UInt64(completedInformation.st_ino)
                == expectedMetadata.inode,
              Int64(completedInformation.st_size)
                == expectedMetadata.size else {
            throw ProvenancePublicationSnapshotError.artifactInspectionFailed(
                path: url.path,
                code: EBUSY
            )
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct ProvenancePublicationRollbackError: Error, LocalizedError {
    public let originalErrorDescription: String
    public let rollbackErrorDescription: String

    public init(originalError: Error, rollbackError: Error) {
        originalErrorDescription = String(reflecting: originalError)
        rollbackErrorDescription = String(reflecting: rollbackError)
    }

    public var errorDescription: String? {
        "Provenance publication failed and rollback failed; original error: \(originalErrorDescription); rollback failed: \(rollbackErrorDescription)"
    }
}

public struct ProvenancePublicationPreservedChangesError:
    Error, LocalizedError, Sendable
{
    public let paths: [String]

    public init(urls: [URL]) {
        paths = urls.map(\.path)
    }

    public var errorDescription: String? {
        "Rollback preserved newer external filesystem generations at: "
            + paths.joined(separator: ", ")
    }
}

public func throwAfterProvenancePublicationFailure(
    _ originalError: Error,
    restore: () throws -> Void
) throws -> Never {
    do {
        try restore()
    } catch {
        throw ProvenancePublicationRollbackError(
            originalError: originalError,
            rollbackError: error
        )
    }
    throw originalError
}

public enum ProvenancePublicationArtifacts {
    public static func bundleRootArtifacts(for rootURL: URL) -> [URL] {
        sidecarArtifacts(for: rootURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            + [rootURL.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)]
    }

    public static func fileSidecarArtifacts(for outputURL: URL) -> [URL] {
        sidecarArtifacts(for: ProvenanceRecorder.fileSidecarURL(for: outputURL))
    }

    public static func sidecarArtifacts(for sidecarURL: URL) -> [URL] {
        [
            sidecarURL,
            ProvenanceSigningConfiguration.signatureURL(for: sidecarURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: sidecarURL),
        ]
    }
}
