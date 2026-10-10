// DurableReplace.swift - Publish a file's new bytes over the old ones without ever emptying its name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization

/// Publishes new bytes under a file name so that the name holds a complete
/// old or new file at every step, on every volume a project can live on.
///
/// One call is one publication (plan decisions S1, V1 and V2).
///
/// 1. The bytes are staged as `.<name>.lungfish-stage-<UUID>`, created with
///    `openat` (`O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC`) on the anchored
///    parent descriptor, written and `fsync`ed.
/// 2. The stage is swapped with the old file through the descriptor form of
///    `renameatx_np` in ``PortableRename``. On APFS the name never empties,
///    and the old file keeps its inode under the stage name. On ExFAT the
///    swap rotates through a `.lungfish-swap-` tombstone, which the next
///    publication of the same name and
///    ``PortableRename/recoverInterruptedSwaps(underProject:maximumDepth:)``
///    restore. A name that holds nothing is published with an exclusive
///    rename instead.
/// 3. The folder is `fsync`ed and the observer sees the publication. When the
///    observer refuses it, the swap is undone, so the old file is back under
///    the name with its own inode, and the new bytes are removed.
/// 4. The retired old copy is unlinked.
/// 5. One `F_FULLFSYNC` per volume follows the last folder sync of the
///    transaction, falling back to `fsync` when a volume refuses it.
///    ``transaction(_:)`` groups many publications under that one flush.
///
/// The parent folder is opened with ``NoFollowFileSystem``, anchored at the
/// outermost `.lungfish*` component or, outside every project and bundle, at
/// the folder itself (plan decision V3). A link below a project or bundle is
/// refused, and links above the anchor are followed.
///
/// The work is synchronous and has no suspension point, so nothing can stop
/// it between the swap and the removal of the retired copy. It never checks
/// cancellation, because a cancelled run still writes its record.
public enum DurableReplace {
    /// The infix of a stage name, `.<name>.lungfish-stage-<UUID>`. It never
    /// holds the tombstone infix, so recovery never mistakes a stage for a
    /// retired generation.
    public static let stageInfix = ".lungfish-stage-"

    /// What one publication did, for an observer.
    public struct Publication: Sendable, Equatable {
        /// The name that now holds the new bytes, as the caller spelled it.
        public let url: URL
        /// Where the old file waits until it is removed, or `nil` when the
        /// name held nothing.
        public let retiredURL: URL?
        /// How the name was published.
        public let mechanism: PortableRename.Mechanism
    }

    /// Thrown by an observer that accepted a publication and then failed.
    /// The new file stays under its name, and ``replace(_:named:in:recovery:beforePublish:observe:)``
    /// rethrows `underlying`.
    public struct AcceptedFailure: Error {
        public let underlying: any Error

        public init(_ underlying: any Error) {
            self.underlying = underlying
        }
    }

    /// What a publication restores first when its name holds nothing.
    public enum Recovery: Sendable, Equatable {
        /// Nothing. For a caller whose observer saw the name empty, where a
        /// restored file would contradict the observer's receipt.
        case none
        /// The newest regular file among the name's `.lungfish-swap-`
        /// tombstones and its asides, `.<name><infix><UUID>` for each infix.
        case restoring(asideInfixes: [String])

        /// Tombstones only.
        public static let tombstones = Recovery.restoring(asideInfixes: [])
    }

    public enum ReplaceError: Error, LocalizedError, Equatable {
        case invalidFileName(String)
        case unsafeDirectory(String)
        /// The name holds something other than a regular file.
        case unsafeExistingEntry(String)
        /// A name no longer identifies the file this publication created.
        case identityMismatch(String)
        case systemFailure(path: String, operation: String, code: Int32)
        /// Undoing a refused publication stopped, and the file at
        /// `retainedPath` keeps what could not be put back.
        case rollbackIncomplete(originalError: String, path: String, retainedPath: String, reason: String)
        /// The new file is published, but the old copy at `retainedPath`
        /// could not be removed.
        case retiredCopyRetained(path: String, retainedPath: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidFileName(let name):
                return "A durable file name must be a single path component: \(name)"
            case .unsafeDirectory(let path):
                return "A durable file's folder must be a real folder with no link below its anchor: \(path)"
            case .unsafeExistingEntry(let path):
                return "\(path) holds something other than a regular file, so it was not replaced."
            case .identityMismatch(let path):
                return "\(path) no longer names the file this publication created."
            case .systemFailure(let path, let operation, let code):
                return "Could not \(operation) at \(path) (errno \(code))."
            case .rollbackIncomplete(let originalError, let path, let retainedPath, let reason):
                return "Publishing \(path) failed (\(originalError)), and undoing it stopped (\(reason)). \(retainedPath) keeps the file that could not be put back."
            case .retiredCopyRetained(let path, let retainedPath, let code):
                return "\(path) holds the new file, but its old copy at \(retainedPath) could not be removed (errno \(code))."
            }
        }
    }

    // MARK: - Publishing

    /// Publishes `data` as `name` in `directoryURL`, swapping out any regular
    /// file the name holds.
    ///
    /// `beforePublish` sees the stage file once its bytes are synced, before
    /// any name changes. `observe` sees the publication after the folder
    /// sync. When either throws, the name keeps its old file and the error is
    /// rethrown, except for an ``AcceptedFailure`` from `observe`, which keeps
    /// the new file and rethrows its underlying error.
    @discardableResult
    public static func replace(
        _ data: Data,
        named name: String,
        in directoryURL: URL,
        recovery: Recovery = .tombstones,
        beforePublish: ((URL) throws -> Void)? = nil,
        observe: ((Publication) throws -> Void)? = nil
    ) throws -> Publication {
        guard isSinglePathComponent(name) else {
            throw ReplaceError.invalidFileName(name)
        }
        let operations = currentOperations
        let directory = try openFolder(directoryURL)
        defer { Darwin.close(directory) }
        let folder = Folder(
            descriptor: directory,
            url: directoryURL,
            name: name,
            operations: operations
        )
        let joined = activeTransaction
        let transaction = joined ?? Transaction()
        do {
            let publication = try folder.publish(
                data,
                recovery: recovery,
                beforePublish: beforePublish,
                observe: observe,
                transaction: transaction
            )
            if joined == nil {
                try transaction.commit(operations: operations)
            }
            return publication
        } catch let accepted as AcceptedFailure {
            if joined == nil {
                try? transaction.commit(operations: operations)
            }
            throw accepted.underlying
        }
    }

    /// Restores `name` in `directoryURL` from its newest leftover when the
    /// name holds nothing. Leftovers are `.lungfish-swap-` tombstones and the
    /// asides named by `asideInfixes`. A leftover beside a present name is
    /// never touched. Returns the restored name, or `nil`.
    @discardableResult
    public static func recover(
        named name: String,
        in directoryURL: URL,
        asideInfixes: [String] = []
    ) throws -> URL? {
        guard isSinglePathComponent(name) else {
            throw ReplaceError.invalidFileName(name)
        }
        let directory = try openFolder(directoryURL)
        defer { Darwin.close(directory) }
        let folder = Folder(
            descriptor: directory,
            url: directoryURL,
            name: name,
            operations: currentOperations
        )
        return try folder.recoverMissingEntry(asideInfixes: asideInfixes) == nil ? nil : folder.url
    }

    // MARK: - Transactions

    /// Runs `body` as one transaction, so every publication inside it shares
    /// one full flush per volume, issued after `body` returns. A transaction
    /// started inside another joins it. When `body` throws, nothing is
    /// flushed, because every publication it made was already `fsync`ed.
    public static func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        if activeTransaction != nil {
            return try body()
        }
        let transaction = Transaction()
        let value = try $activeTransaction.withValue(transaction) {
            try body()
        }
        try transaction.commit(operations: currentOperations)
        return value
    }

    /// Adds a folder that another durable writer has just synchronized to the
    /// current transaction, so its full flush covers that folder too.
    /// Outside a transaction the folder's volume is flushed at once.
    public static func noteSynchronizedFolder(at directoryURL: URL) throws {
        let directory = try openFolder(directoryURL)
        defer { Darwin.close(directory) }
        let joined = activeTransaction
        let transaction = joined ?? Transaction()
        transaction.noteSynchronized(directory)
        if joined == nil {
            try transaction.commit(operations: currentOperations)
        }
    }

    /// The folders a transaction has synchronized, one open descriptor per
    /// volume, flushed once when the transaction ends.
    public final class Transaction: Sendable {
        private let folders = Mutex<[UInt64: Int32]>([:])

        init() {}

        deinit {
            folders.withLock { open in
                for descriptor in open.values {
                    Darwin.close(descriptor)
                }
                open.removeAll()
            }
        }

        /// Keeps the latest synchronized folder of each volume.
        func noteSynchronized(_ directoryDescriptor: Int32) {
            var information = stat()
            guard Darwin.fstat(directoryDescriptor, &information) == 0 else { return }
            let copy = Darwin.fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { return }
            folders.withLock { open in
                if let previous = open.updateValue(copy, forKey: UInt64(information.st_dev)) {
                    Darwin.close(previous)
                }
            }
        }

        func commit(operations: Operations) throws {
            let open = folders.withLock { open -> [UInt64: Int32] in
                let taken = open
                open.removeAll()
                return taken
            }
            guard !open.isEmpty else { return }
            var failure: ReplaceError?
            for device in open.keys.sorted() {
                guard let descriptor = open[device] else { continue }
                defer { Darwin.close(descriptor) }
                if operations.fullFlush(descriptor) == 0 || operations.syncDirectory(descriptor) == 0 {
                    continue
                }
                failure = failure ?? .systemFailure(
                    path: DurableReplace.path(of: descriptor),
                    operation: "flush the volume",
                    code: errno
                )
            }
            if let failure {
                throw failure
            }
            try operations.checkpoint(.flushed)
        }
    }

    @TaskLocal static var activeTransaction: Transaction?

    // MARK: - Seam

    /// The points a test can fail at, or end its process at, in order.
    package enum Step: String, CaseIterable, Sendable {
        /// The stage file holds the new bytes.
        case staged
        /// The stage file is `fsync`ed.
        case stageSynced
        /// The name holds the new bytes and, after a swap, the stage name
        /// holds the old ones.
        case published
        /// The folder is `fsync`ed.
        case folderSynced
        /// The observer accepted the publication.
        case observed
        /// The retired copy is unlinked.
        case retiredRemoved
        /// The transaction's full flush is issued.
        case flushed
    }

    /// The system calls a publication makes. Tests replace them through
    /// ``overrideOperations``. Faults in the renames themselves, the ExFAT
    /// rotation among them, go through `rename`.
    package struct Operations: Sendable {
        package var rename: PortableRename.Operations
        package var syncFile: @Sendable (Int32) -> Int32
        package var syncDirectory: @Sendable (Int32) -> Int32
        package var fullFlush: @Sendable (Int32) -> Int32
        package var removeEntry: @Sendable (Int32, String) -> Int32
        package var checkpoint: @Sendable (Step) throws -> Void

        package init(
            rename: PortableRename.Operations = .current,
            syncFile: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) },
            syncDirectory: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) },
            fullFlush: @escaping @Sendable (Int32) -> Int32 = { Darwin.fcntl($0, F_FULLFSYNC) },
            removeEntry: @escaping @Sendable (Int32, String) -> Int32 = { descriptor, name in
                name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
            },
            checkpoint: @escaping @Sendable (Step) throws -> Void = { _ in }
        ) {
            self.rename = rename
            self.syncFile = syncFile
            self.syncDirectory = syncDirectory
            self.fullFlush = fullFlush
            self.removeEntry = removeEntry
            self.checkpoint = checkpoint
        }
    }

    /// Replaces the system calls for the current task and the synchronous
    /// calls it makes.
    @TaskLocal package static var overrideOperations: Operations?

    package static var currentOperations: Operations {
        overrideOperations ?? Operations()
    }

    // MARK: - Helpers

    private static func openFolder(_ directoryURL: URL) throws -> Int32 {
        do {
            return try NoFollowFileSystem.openDirectoryHierarchy(
                directoryURL,
                anchoredAt: NoFollowFileSystem.trustedAnchor(for: directoryURL) ?? directoryURL
            )
        } catch {
            throw ReplaceError.unsafeDirectory(directoryURL.path)
        }
    }

    static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.utf8.contains(0)
    }

    static func path(of descriptor: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return "descriptor \(descriptor)" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

// MARK: - One folder

extension DurableReplace {
    /// A file's identity on its volume.
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ information: stat) {
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
        }
    }

    enum EntryKind: Equatable {
        case missing
        case regular(Identity)
        case other
    }

    /// The anchored parent descriptor of one name and the calls made on it.
    struct Folder {
        let descriptor: Int32
        let url: URL
        let name: String
        let operations: Operations
        private let directoryURL: URL

        init(descriptor: Int32, url directoryURL: URL, name: String, operations: Operations) {
            self.descriptor = descriptor
            self.directoryURL = directoryURL
            self.name = name
            self.operations = operations
            url = directoryURL.appendingPathComponent(name)
        }

        func url(of entry: String) -> URL {
            directoryURL.appendingPathComponent(entry)
        }

        func publish(
            _ data: Data,
            recovery: Recovery,
            beforePublish: ((URL) throws -> Void)?,
            observe: ((Publication) throws -> Void)?,
            transaction: Transaction
        ) throws -> Publication {
            if case .restoring(let asideInfixes) = recovery {
                try recoverMissingEntry(asideInfixes: asideInfixes)
            }
            let stageName = ".\(name)\(DurableReplace.stageInfix)\(UUID().uuidString)"
            let staged = try stage(data, as: stageName)

            let existing: EntryKind
            do {
                try beforePublish?(url(of: stageName))
                existing = try kind(of: name)
                guard existing != .other else {
                    throw ReplaceError.unsafeExistingEntry(url.path)
                }
                guard try kind(of: stageName) == .regular(staged) else {
                    throw ReplaceError.identityMismatch(url(of: stageName).path)
                }
            } catch {
                removeEntry(stageName, ifItIs: staged)
                throw error
            }

            let swapping = existing != .missing
            let outcome = rename(stageName, name, flags: swapping ? RENAME_SWAP : RENAME_EXCL)
            guard outcome.status == 0 else {
                let code = errno
                removeEntry(stageName, ifItIs: staged)
                throw ReplaceError.systemFailure(
                    path: url.path,
                    operation: swapping ? "swap in the new file" : "publish the new file",
                    code: code
                )
            }
            let publication = Publication(
                url: url,
                retiredURL: swapping ? url(of: stageName) : nil,
                mechanism: outcome.mechanism
            )

            do {
                guard try kind(of: name) == .regular(staged) else {
                    throw ReplaceError.identityMismatch(url.path)
                }
                if swapping, try kind(of: stageName) != existing {
                    throw ReplaceError.unsafeExistingEntry(url.path)
                }
                try operations.checkpoint(.published)
                guard operations.syncDirectory(descriptor) == 0 else {
                    throw ReplaceError.systemFailure(path: directoryURL.path, operation: "fsync the folder", code: errno)
                }
                try operations.checkpoint(.folderSynced)
                try observe?(publication)
            } catch let accepted as AcceptedFailure {
                transaction.noteSynchronized(descriptor)
                if case .regular(let retired) = existing {
                    removeEntry(stageName, ifItIs: retired)
                }
                throw accepted
            } catch {
                try rollBack(stageName: stageName, staged: staged, swapped: swapping, originalError: error)
                throw error
            }

            // Accepted. Every failure from here on keeps the new file.
            transaction.noteSynchronized(descriptor)
            var keptFailure: (any Error)?
            do {
                try operations.checkpoint(.observed)
            } catch {
                keptFailure = error
            }
            if case .regular(let retired) = existing, !removeEntry(stageName, ifItIs: retired) {
                throw keptFailure ?? ReplaceError.retiredCopyRetained(
                    path: url.path,
                    retainedPath: url(of: stageName).path,
                    code: errno
                )
            }
            if let keptFailure {
                throw keptFailure
            }
            try operations.checkpoint(.retiredRemoved)
            return publication
        }

        /// Creates, writes and syncs the stage file. A failure removes it.
        private func stage(_ data: Data, as stageName: String) throws -> Identity {
            let stageURL = url(of: stageName)
            let file = stageName.withCString {
                Darwin.openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
            }
            guard file >= 0 else {
                throw ReplaceError.systemFailure(path: stageURL.path, operation: "create the stage file", code: errno)
            }
            defer { Darwin.close(file) }
            var information = stat()
            guard Darwin.fstat(file, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG else {
                let code = errno
                _ = operations.removeEntry(descriptor, stageName)
                throw ReplaceError.systemFailure(path: stageURL.path, operation: "inspect the stage file", code: code)
            }
            let staged = Identity(information)
            do {
                try Self.writeAll(data, to: file, path: stageURL.path)
                try operations.checkpoint(.staged)
                guard operations.syncFile(file) == 0 else {
                    throw ReplaceError.systemFailure(path: stageURL.path, operation: "fsync the stage file", code: errno)
                }
                try operations.checkpoint(.stageSynced)
            } catch {
                removeEntry(stageName, ifItIs: staged)
                throw error
            }
            return staged
        }

        /// Puts the old file back under the name, or empties a name that held
        /// nothing, then removes the refused bytes.
        private func rollBack(
            stageName: String,
            staged: Identity,
            swapped: Bool,
            originalError: any Error
        ) throws {
            let stageURL = url(of: stageName)
            func incomplete(_ reason: String, retained: URL) -> ReplaceError {
                .rollbackIncomplete(
                    originalError: originalError.localizedDescription,
                    path: url.path,
                    retainedPath: retained.path,
                    reason: reason
                )
            }
            if swapped {
                guard rename(stageName, name, flags: RENAME_SWAP).status == 0 else {
                    throw incomplete("the swap back failed with errno \(errno)", retained: stageURL)
                }
                guard (try? kind(of: stageName)) == .regular(staged) else {
                    // Another writer replaced the name after the swap. Its
                    // file goes back under the name and the old copy stays.
                    _ = rename(stageName, name, flags: RENAME_SWAP)
                    throw incomplete("another writer replaced the name", retained: stageURL)
                }
            } else {
                guard rename(name, stageName, flags: RENAME_EXCL).status == 0 else {
                    if errno == ENOENT { return }
                    throw incomplete("detaching the new file failed with errno \(errno)", retained: url)
                }
                guard (try? kind(of: stageName)) == .regular(staged) else {
                    _ = rename(stageName, name, flags: RENAME_EXCL)
                    throw incomplete("another writer replaced the name", retained: url)
                }
            }
            _ = operations.removeEntry(descriptor, stageName)
            _ = operations.syncDirectory(descriptor)
        }

        /// Restores the name from its newest regular leftover when it holds
        /// nothing, and returns the leftover's name.
        @discardableResult
        func recoverMissingEntry(asideInfixes: [String]) throws -> String? {
            guard try kind(of: name) == .missing else { return nil }
            let prefix = ".\(name)"
            let infixes = [PortableRename.swapTombstoneInfix] + asideInfixes
            var chosen: (entry: String, modified: timespec)?
            for entry in try entryNames() where entry.hasPrefix(prefix) {
                let rest = entry.dropFirst(prefix.count)
                guard let infix = infixes.first(where: { rest.hasPrefix($0) }),
                      UUID(uuidString: String(rest.dropFirst(infix.count))) != nil else { continue }
                var information = stat()
                guard entry.withCString({ Darwin.fstatat(descriptor, $0, &information, AT_SYMLINK_NOFOLLOW) }) == 0,
                      information.st_mode & S_IFMT == S_IFREG else { continue }
                if let current = chosen, !Self.isNewer(information.st_mtimespec, entry, than: current) {
                    continue
                }
                chosen = (entry, information.st_mtimespec)
            }
            guard let chosen else { return nil }
            guard rename(chosen.entry, name, flags: RENAME_EXCL).status == 0 else {
                if errno == EEXIST { return nil }
                throw ReplaceError.systemFailure(path: url.path, operation: "restore \(chosen.entry)", code: errno)
            }
            _ = operations.syncDirectory(descriptor)
            return chosen.entry
        }

        func kind(of entry: String) throws -> EntryKind {
            var information = stat()
            let status = entry.withCString {
                Darwin.fstatat(descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                if errno == ENOENT { return .missing }
                throw ReplaceError.systemFailure(path: url(of: entry).path, operation: "inspect", code: errno)
            }
            return information.st_mode & S_IFMT == S_IFREG ? .regular(Identity(information)) : .other
        }

        private func rename(_ source: String, _ destination: String, flags: Int32) -> PortableRename.Outcome {
            source.withCString { sourceName in
                destination.withCString { destinationName in
                    PortableRename.renameatxNPReporting(
                        descriptor,
                        sourceName,
                        descriptor,
                        destinationName,
                        UInt32(flags),
                        operations: operations.rename
                    )
                }
            }
        }

        /// Unlinks `entry` when it is still the file `identity` names.
        /// Returns false only when that unlink fails.
        @discardableResult
        private func removeEntry(_ entry: String, ifItIs identity: Identity) -> Bool {
            guard (try? kind(of: entry)) == .regular(identity) else { return true }
            return operations.removeEntry(descriptor, entry) == 0
        }

        private func entryNames() throws -> [String] {
            let copy = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0, let stream = Darwin.fdopendir(copy) else {
                let code = errno
                if copy >= 0 { Darwin.close(copy) }
                throw ReplaceError.systemFailure(path: directoryURL.path, operation: "list the folder", code: code)
            }
            defer { Darwin.closedir(stream) }
            Darwin.rewinddir(stream)
            var names: [String] = []
            while let entry = Darwin.readdir(stream) {
                let length = Int(entry.pointee.d_namlen)
                let entryName = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix(length), as: UTF8.self)
                }
                if entryName != "." && entryName != ".." {
                    names.append(entryName)
                }
            }
            return names
        }

        private static func isNewer(
            _ modified: timespec,
            _ entry: String,
            than current: (entry: String, modified: timespec)
        ) -> Bool {
            if modified.tv_sec != current.modified.tv_sec { return modified.tv_sec > current.modified.tv_sec }
            if modified.tv_nsec != current.modified.tv_nsec { return modified.tv_nsec > current.modified.tv_nsec }
            return entry > current.entry
        }

        private static func writeAll(_ data: Data, to file: Int32, path: String) throws {
            try data.withUnsafeBytes { buffer in
                guard var cursor = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let count = Darwin.write(file, cursor, remaining)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw ReplaceError.systemFailure(
                            path: path,
                            operation: "write the stage file",
                            code: count < 0 ? errno : EIO
                        )
                    }
                    remaining -= count
                    cursor = cursor.advanced(by: count)
                }
            }
        }
    }
}
